import AVFoundation
import Foundation
import Speech

struct SpeechTranscriptionUpdate: Sendable {
    let text: String
    let isFinal: Bool
}

protocol SpeechRecognitionSession: AnyObject {
    func append(_ buffer: AVAudioPCMBuffer)
    func finishAudio()
    func cancel()
}

final class AppleSpeechRecognitionSession: SpeechRecognitionSession {
    private let recognizer: SFSpeechRecognizer
    private let request: SFSpeechAudioBufferRecognitionRequest
    private let task: SFSpeechRecognitionTask

    init(
        locale: Locale,
        onUpdate: @escaping @Sendable (Result<SpeechTranscriptionUpdate, Error>) -> Void
    ) throws {
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw TranscriberError.recognizerUnavailable
        }
        guard recognizer.isAvailable else {
            throw TranscriberError.recognizerUnavailable
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw TranscriberError.onDeviceRecognitionUnavailable
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true

        self.recognizer = recognizer
        self.request = request
        self.task = recognizer.recognitionTask(with: request) { result, error in
            if let result {
                onUpdate(.success(
                    SpeechTranscriptionUpdate(
                        text: result.bestTranscription.formattedString,
                        isFinal: result.isFinal
                    )
                ))
            }
            if let error {
                onUpdate(.failure(error))
            }
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        request.append(buffer)
    }

    func finishAudio() {
        request.endAudio()
    }

    func cancel() {
        task.cancel()
        request.endAudio()
    }
}

enum SpeechAuthorizationState: Sendable {
    case authorized
    case denied
    case restricted
    case notDetermined
}

enum TranscriberError: LocalizedError {
    case speechRecognitionNotAuthorized
    case recognizerUnavailable
    case onDeviceRecognitionUnavailable
    case noTranscript

    var errorDescription: String? {
        switch self {
        case .speechRecognitionNotAuthorized:
            return "Speech Recognition access is required for live transcription."
        case .recognizerUnavailable:
            return "Speech Recognition is unavailable on this Mac right now."
        case .onDeviceRecognitionUnavailable:
            return "This Mac does not support on-device Apple Speech Recognition for CrispVoice."
        case .noTranscript:
            return "No transcript was captured."
        }
    }
}

/// Streams live transcription from Apple Speech and returns the final transcript on stop.
///
/// Apple partials within a recognition window are cumulative replacements, not additive
/// chunks. `currentPartial` always holds Apple's latest view of the current window.
/// `finalizedText` accumulates text from windows closed by an `isFinal=true` result.
final class Transcriber {
    typealias AuthorizationProvider = @Sendable () async -> SpeechAuthorizationState
    typealias SessionFactory = @Sendable (
        @escaping @Sendable (Result<SpeechTranscriptionUpdate, Error>) -> Void
    ) throws -> SpeechRecognitionSession

    private let authorizationProvider: AuthorizationProvider
    private let sessionFactory: SessionFactory
    private let lock = NSLock()

    private var session: SpeechRecognitionSession?
    private var partialHandler: (@Sendable (String) -> Void)?
    private var latestTranscript = ""
    private var finalizedText = ""
    private var currentPartial = ""
    private var finalContinuation: CheckedContinuation<String, Error>?
    private var terminalResult: Result<String, Error>?
    private var isFinished = false
    private var finishRequested = false
    // Incremented on every cancel/restart so stale callbacks from a previous session
    // that fire after the new session has started are silently ignored.
    private var sessionGeneration = 0

    init(locale: Locale = Locale(identifier: "en-US")) {
        self.authorizationProvider = {
            await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    let mappedStatus: SpeechAuthorizationState
                    switch status {
                    case .authorized:
                        mappedStatus = .authorized
                    case .denied:
                        mappedStatus = .denied
                    case .restricted:
                        mappedStatus = .restricted
                    case .notDetermined:
                        mappedStatus = .notDetermined
                    @unknown default:
                        mappedStatus = .denied
                    }
                    continuation.resume(returning: mappedStatus)
                }
            }
        }

        self.sessionFactory = { handler in
            try AppleSpeechRecognitionSession(locale: locale, onUpdate: handler)
        }
    }

    init(
        authorizationProvider: @escaping AuthorizationProvider,
        sessionFactory: @escaping SessionFactory
    ) {
        self.authorizationProvider = authorizationProvider
        self.sessionFactory = sessionFactory
    }

    func startLiveTranscription(onPartialResult: @escaping @Sendable (String) -> Void) async throws {
        let status = await authorizationProvider()
        guard status == .authorized else {
            throw TranscriberError.speechRecognitionNotAuthorized
        }

        cancel()

        // Read the generation AFTER cancel() has incremented it so the new session's
        // callbacks carry the updated value and stale old-session callbacks are dropped.
        let capturedGeneration = withLockedState { sessionGeneration }
        let session = try sessionFactory { [weak self] result in
            self?.handle(result, ifGeneration: capturedGeneration)
        }

        withLockedState {
            self.session = session
            partialHandler = onPartialResult
            latestTranscript = ""
            finalizedText = ""
            currentPartial = ""
            finalContinuation = nil
            terminalResult = nil
            isFinished = false
            finishRequested = false
        }
    }

    func appendAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        let session = withLockedState { self.session }
        session?.append(buffer)
    }

    func finishTranscription() async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            let (immediateResult, sessionToFinish) = withLockedState {
                () -> (Result<String, Error>?, SpeechRecognitionSession?) in
                finishRequested = true

                if let existingResult = terminalResult {
                    return (existingResult, nil)
                }

                // If the current window already closed (no pending partial) and we have
                // finalized content, return immediately without waiting for another event.
                if currentPartial.isEmpty && !finalizedText.isEmpty {
                    return (.success(finalizedText), nil)
                }

                finalContinuation = continuation
                return (nil, session)
            }

            DebugLog.write(
                "Transcriber.finishTranscription immediate=\(immediateResult != nil) hasSession=\(sessionToFinish != nil)"
            )

            if let immediateResult {
                continuation.resume(with: immediateResult)
            } else {
                sessionToFinish?.finishAudio()
            }
        }
    }

    func cancel() {
        let state = withLockedState {
            let state = (session, finalContinuation)
            sessionGeneration += 1
            session = nil
            partialHandler = nil
            finalContinuation = nil
            terminalResult = nil
            finalizedText = ""
            currentPartial = ""
            latestTranscript = ""
            isFinished = false
            finishRequested = false
            return state
        }

        state.0?.cancel()
        state.1?.resume(throwing: CancellationError())
    }

    private func handle(_ result: Result<SpeechTranscriptionUpdate, Error>, ifGeneration generation: Int) {
        guard withLockedState({ sessionGeneration == generation }) else { return }
        switch result {
        case .success(let update):
            handleSuccess(update)
        case .failure(let error):
            complete(with: .failure(error))
        }
    }

    private func handleSuccess(_ update: SpeechTranscriptionUpdate) {
        let normalized = normalizedTranscript(update.text) ?? ""

        var handlerToCall: ((String) -> Void)?
        var publishedTranscript = ""
        var shouldComplete = false

        withLockedState {
            guard !isFinished else { return }

            let previous = latestTranscript

            if update.isFinal {
                // Apple finished this recognition window. Prefer Apple's final text when
                // non-empty; fall back to whatever partial we accumulated for this window.
                let windowText = normalized.isEmpty ? currentPartial : normalized
                if !windowText.isEmpty {
                    finalizedText = [finalizedText, windowText]
                        .filter { !$0.isEmpty }
                        .joined(separator: " ")
                }
                currentPartial = ""
            } else if !normalized.isEmpty {
                let currentWords = currentPartial.split(whereSeparator: \.isWhitespace).map(String.init)
                let incomingWords = normalized.split(whereSeparator: \.isWhitespace).map(String.init)
                // Detect when Apple silently started a new recognition window after a pause
                // without sending isFinal=true for the previous window. Two reliable signals:
                //   Signal 1 — first word changed: Apple never changes the first word within
                //     a single window's refinements.
                //   Signal 2 — dramatic shortening: same-window corrections never drop below
                //     40% of the current word count. A post-pause restart does, because Apple
                //     only has a word or two of the new utterance transcribed so far.
                let firstWordChanged = !currentWords.isEmpty && !incomingWords.isEmpty &&
                    canonicalToken(incomingWords[0]) != canonicalToken(currentWords[0])
                let wordRatio = currentWords.isEmpty ? 1.0
                    : Double(incomingWords.count) / Double(currentWords.count)
                let isDramaticShortening = !currentWords.isEmpty
                    && incomingWords.count < currentWords.count
                    && wordRatio < 0.4
                if firstWordChanged || isDramaticShortening {
                    // Commit the completed window before starting the new one.
                    finalizedText = [finalizedText, currentPartial]
                        .filter { !$0.isEmpty }
                        .joined(separator: " ")
                    currentPartial = normalized
                } else {
                    currentPartial = deduplicatedPartial(normalized, relativeTo: currentPartial)
                }
            }

            latestTranscript = [finalizedText, currentPartial]
                .filter { !$0.isEmpty }
                .joined(separator: " ")

            if latestTranscript != previous {
                handlerToCall = self.partialHandler
            }
            publishedTranscript = latestTranscript
            shouldComplete = update.isFinal && finishRequested
        }

        DebugLog.write(
            "Transcriber.handleSuccess incomingLength=\(update.text.count) incomingFP=\(DebugLog.fingerprint(update.text)) mergedLength=\(publishedTranscript.count) mergedFP=\(DebugLog.fingerprint(publishedTranscript)) isFinal=\(update.isFinal)"
        )

        if !publishedTranscript.isEmpty {
            handlerToCall?(publishedTranscript)
        }

        if shouldComplete {
            if publishedTranscript.isEmpty {
                complete(with: .failure(TranscriberError.noTranscript))
            } else {
                complete(with: .success(publishedTranscript))
            }
        }
    }

    private func shouldCompleteOnFinalUpdate() -> Bool {
        withLockedState { finishRequested }
    }

    private func complete(with result: Result<String, Error>) {
        let continuation = withLockedState { () -> CheckedContinuation<String, Error>? in
            guard !isFinished else {
                return nil
            }
            isFinished = true
            terminalResult = result
            let continuation = finalContinuation
            finalContinuation = nil
            session = nil
            partialHandler = nil
            return continuation
        }

        continuation?.resume(with: result)
    }

    // MARK: - Partial deduplication

    /// Strips a repeated `currentPartial` prefix that Apple echoed before new words.
    ///
    /// Apple sometimes sends: "[current words] [current words] [new words]".
    /// This returns "[current words] [new words]" instead of appending everything.
    /// When incoming is shorter than or equal to currentPartial (a revision or same
    /// content), it is returned unchanged — replacing the current partial is correct.
    private func deduplicatedPartial(_ incoming: String, relativeTo currentPartial: String) -> String {
        guard !currentPartial.isEmpty else { return incoming }

        let currentWords = currentPartial.split(whereSeparator: \.isWhitespace).map(String.init)
        let incomingWords = incoming.split(whereSeparator: \.isWhitespace).map(String.init)

        guard incomingWords.count > currentWords.count,
              wordsMatch(Array(incomingWords.prefix(currentWords.count)), currentWords)
        else {
            // Incoming is shorter/same, or doesn't start with current — just replace.
            return incoming
        }

        // Apple echoed back our current content. Merge the remainder.
        let remainder = Array(incomingWords.dropFirst(currentWords.count))
        let overlap = longestSuffixPrefixOverlap(existingWords: currentWords, incomingWords: remainder)
        if overlap == remainder.count {
            return currentPartial
        }
        return (currentWords + remainder.dropFirst(overlap)).joined(separator: " ")
    }

    private func longestSuffixPrefixOverlap(existingWords: [String], incomingWords: [String]) -> Int {
        let limit = min(existingWords.count, incomingWords.count)
        guard limit > 0 else { return 0 }
        for count in stride(from: limit, through: 1, by: -1) {
            if wordsMatch(Array(existingWords.suffix(count)), Array(incomingWords.prefix(count))) {
                return count
            }
        }
        return 0
    }

    private func wordsMatch(_ lhs: [String], _ rhs: [String]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { canonicalToken($0) == canonicalToken($1) }
    }

    private func canonicalToken(_ token: String) -> String {
        token.trimmingCharacters(in: .punctuationCharacters).lowercased()
    }

    // MARK: - Normalization

    private func normalizedTranscript(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return collapseRepeatedPhrase(in: trimmed)
    }

    private func collapseRepeatedPhrase(in text: String) -> String {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)

        guard words.count >= 6 else { return text }

        for phraseLength in 3...(words.count / 2) {
            guard words.count.isMultiple(of: phraseLength) else { continue }

            let phrase = Array(words.prefix(phraseLength))
            let chunkCount = words.count / phraseLength

            guard chunkCount >= 2 else { continue }

            let isRepeated = stride(from: 0, to: words.count, by: phraseLength).allSatisfy { index in
                Array(words[index..<(index + phraseLength)]) == phrase
            }

            if isRepeated {
                return phrase.joined(separator: " ")
            }
        }

        return text
    }

    private func withLockedState<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
