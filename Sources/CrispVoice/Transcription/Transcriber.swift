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
    private var finalContinuation: CheckedContinuation<String, Error>?
    private var terminalResult: Result<String, Error>?
    private var isFinished = false

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

        let session = try sessionFactory { [weak self] result in
            self?.handle(result)
        }

        withLockedState {
            self.session = session
            partialHandler = onPartialResult
            latestTranscript = ""
            finalContinuation = nil
            terminalResult = nil
            isFinished = false
        }
    }

    func appendAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        let session = withLockedState { self.session }
        session?.append(buffer)
    }

    func finishTranscription() async throws -> String {
        let state = withLockedState { (terminalResult, session) }
        let immediateResult = state.0

        if immediateResult == nil {
            state.1?.finishAudio()
        }

        if let immediateResult {
            return try immediateResult.get()
        }

        return try await withCheckedThrowingContinuation { continuation in
            let terminalResult = withLockedState { () -> Result<String, Error>? in
                if let existingResult = self.terminalResult {
                    return existingResult
                }
                if let latest = self.normalizedTranscript(self.latestTranscript), self.isFinished {
                    return .success(latest)
                }

                finalContinuation = continuation
                return nil
            }

            if let terminalResult {
                continuation.resume(with: terminalResult)
            }
        }
    }

    func cancel() {
        let state = withLockedState {
            let state = (session, finalContinuation)
            session = nil
            partialHandler = nil
            finalContinuation = nil
            terminalResult = nil
            latestTranscript = ""
            isFinished = false
            return state
        }

        state.0?.cancel()
        state.1?.resume(throwing: CancellationError())
    }

    private func handle(_ result: Result<SpeechTranscriptionUpdate, Error>) {
        switch result {
        case .success(let update):
            handleSuccess(update)
        case .failure(let error):
            complete(with: .failure(error))
        }
    }

    private func handleSuccess(_ update: SpeechTranscriptionUpdate) {
        let text = normalizedTranscript(update.text) ?? currentTranscriptFallback()
        let partialHandler = withLockedState { () -> ((String) -> Void)? in
            if isFinished {
                return nil
            }

            latestTranscript = text
            return self.partialHandler
        }

        if !text.isEmpty {
            partialHandler?(text)
        }

        if update.isFinal {
            if text.isEmpty {
                complete(with: .failure(TranscriberError.noTranscript))
            } else {
                complete(with: .success(text))
            }
        }
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

    private func currentTranscriptFallback() -> String {
        withLockedState { latestTranscript }
    }

    private func normalizedTranscript(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func withLockedState<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
