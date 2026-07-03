import AVFoundation
import XCTest
@testable import CrispVoice

private actor PartialSink {
    private(set) var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }

    func snapshot() -> [String] {
        values
    }
}

private final class StubSpeechRecognitionSession: SpeechRecognitionSession {
    private let onUpdate: @Sendable (Result<SpeechTranscriptionUpdate, Error>) -> Void

    private(set) var appendedBufferCount = 0
    private(set) var didFinishAudio = false
    private(set) var didCancel = false

    init(onUpdate: @escaping @Sendable (Result<SpeechTranscriptionUpdate, Error>) -> Void) {
        self.onUpdate = onUpdate
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        appendedBufferCount += 1
    }

    func finishAudio() {
        didFinishAudio = true
    }

    func cancel() {
        didCancel = true
    }

    func emit(text: String, isFinal: Bool) {
        onUpdate(.success(SpeechTranscriptionUpdate(text: text, isFinal: isFinal)))
    }

    func fail(_ error: Error) {
        onUpdate(.failure(error))
    }
}

private final class StubSessionFactory {
    private(set) var session: StubSpeechRecognitionSession?

    func makeSession(
        onUpdate: @escaping @Sendable (Result<SpeechTranscriptionUpdate, Error>) -> Void
    ) -> SpeechRecognitionSession {
        let session = StubSpeechRecognitionSession(onUpdate: onUpdate)
        self.session = session
        return session
    }
}

final class TranscriberTests: XCTestCase {
    func test_liveTranscriptionPublishesPartialsAndReturnsFinalTranscript() async throws {
        let factory = StubSessionFactory()
        let transcriber = Transcriber(
            authorizationProvider: { .authorized },
            sessionFactory: { factory.makeSession(onUpdate: $0) }
        )
        let buffer = makeBuffer()
        let partials = PartialSink()

        try await transcriber.startLiveTranscription { text in
            Task { await partials.append(text) }
        }
        transcriber.appendAudioBuffer(buffer)
        factory.session?.emit(text: "  hello there  ", isFinal: false)

        let finishTask = Task { try await transcriber.finishTranscription() }
        await Task.yield()
        XCTAssertEqual(factory.session?.appendedBufferCount, 1)
        for _ in 0..<10 where factory.session?.didFinishAudio != true {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(factory.session?.didFinishAudio, true)

        factory.session?.emit(text: "  hello there world \n", isFinal: true)
        let finalTranscript = try await finishTask.value
        try await Task.sleep(nanoseconds: 1_000_000)

        let partialSnapshot = await partials.snapshot()
        XCTAssertEqual(partialSnapshot, ["hello there", "hello there world"])
        XCTAssertEqual(finalTranscript, "hello there world")
    }

    func test_finishFallsBackToLatestPartialWhenFinalResultIsEmpty() async throws {
        let factory = StubSessionFactory()
        let transcriber = Transcriber(
            authorizationProvider: { .authorized },
            sessionFactory: { factory.makeSession(onUpdate: $0) }
        )

        try await transcriber.startLiveTranscription { _ in }
        factory.session?.emit(text: "partial transcript", isFinal: false)

        let finishTask = Task { try await transcriber.finishTranscription() }
        await Task.yield()
        factory.session?.emit(text: "   ", isFinal: true)

        let finalTranscript = try await finishTask.value
        XCTAssertEqual(finalTranscript, "partial transcript")
    }

    func test_liveTranscription_commitsCurrentPartialWhenAppleStartsNewWindowWithoutFinal() async throws {
        // Apple sometimes starts a fresh recognition window after a pause without sending
        // isFinal=true for the previous window. Detected by the first word changing — Apple
        // never changes the first word within a single window's refinements. When detected,
        // the previous partial is committed to finalizedText before the new window begins.
        let factory = StubSessionFactory()
        let transcriber = Transcriber(
            authorizationProvider: { .authorized },
            sessionFactory: { factory.makeSession(onUpdate: $0) }
        )
        let partials = PartialSink()

        try await transcriber.startLiveTranscription { text in
            Task { await partials.append(text) }
        }
        // First window: "please send the latest deck"
        factory.session?.emit(text: "please send the latest deck", isFinal: false)
        // Apple starts new window without isFinal — first word "before" != "please"
        factory.session?.emit(text: "before the three pm sync", isFinal: false)

        let finishTask = Task { try await transcriber.finishTranscription() }
        await Task.yield()
        factory.session?.emit(text: "before the three pm sync", isFinal: true)

        let finalTranscript = try await finishTask.value
        try await Task.sleep(nanoseconds: 1_000_000)
        let partialSnapshot = await partials.snapshot()
        XCTAssertGreaterThanOrEqual(partialSnapshot.count, 2)
        XCTAssertEqual(partialSnapshot[0], "please send the latest deck")
        XCTAssertEqual(partialSnapshot.last, "please send the latest deck before the three pm sync")
        XCTAssertEqual(finalTranscript, "please send the latest deck before the three pm sync")
    }

    func test_liveTranscription_doesNotCompleteWhenSpeechMarksAnUtteranceFinalBeforeStop() async throws {
        let factory = StubSessionFactory()
        let transcriber = Transcriber(
            authorizationProvider: { .authorized },
            sessionFactory: { factory.makeSession(onUpdate: $0) }
        )
        let partials = PartialSink()

        try await transcriber.startLiveTranscription { text in
            Task { await partials.append(text) }
        }

        factory.session?.emit(text: "please send the latest deck", isFinal: false)
        factory.session?.emit(text: "please send the latest deck", isFinal: true)
        factory.session?.emit(text: "before the three pm sync", isFinal: false)

        let finishTask = Task { try await transcriber.finishTranscription() }
        await Task.yield()
        factory.session?.emit(text: "before the three pm sync", isFinal: true)

        try await Task.sleep(nanoseconds: 1_000_000)
        let partialSnapshot = await partials.snapshot()
        XCTAssertGreaterThanOrEqual(partialSnapshot.count, 2)
        XCTAssertEqual(partialSnapshot[0], "please send the latest deck")
        XCTAssertEqual(partialSnapshot.last, "please send the latest deck before the three pm sync")
        let finalTranscript = try await finishTask.value
        XCTAssertEqual(finalTranscript, "please send the latest deck before the three pm sync")
    }

    func test_liveTranscription_doesNotRepublishIdenticalTranscriptUpdates() async throws {
        let factory = StubSessionFactory()
        let transcriber = Transcriber(
            authorizationProvider: { .authorized },
            sessionFactory: { factory.makeSession(onUpdate: $0) }
        )
        let partials = PartialSink()

        try await transcriber.startLiveTranscription { text in
            Task { await partials.append(text) }
        }

        factory.session?.emit(text: "send the deck", isFinal: false)
        factory.session?.emit(text: "send the deck", isFinal: false)
        factory.session?.emit(text: "send the deck", isFinal: true)

        let finishTask = Task { try await transcriber.finishTranscription() }
        await Task.yield()
        factory.session?.emit(text: "send the deck", isFinal: true)

        _ = try await finishTask.value
        let partialSnapshot = await partials.snapshot()
        XCTAssertEqual(partialSnapshot, ["send the deck"])
    }

    func test_liveTranscription_collapsesRepeatedSentenceInIncomingUpdate() async throws {
        let factory = StubSessionFactory()
        let transcriber = Transcriber(
            authorizationProvider: { .authorized },
            sessionFactory: { factory.makeSession(onUpdate: $0) }
        )
        let partials = PartialSink()

        try await transcriber.startLiveTranscription { text in
            Task { await partials.append(text) }
        }

        factory.session?.emit(text: "please send the latest deck", isFinal: false)
        factory.session?.emit(
            text: "please send the latest deck please send the latest deck",
            isFinal: false
        )

        let finishTask = Task { try await transcriber.finishTranscription() }
        await Task.yield()
        factory.session?.emit(text: "please send the latest deck", isFinal: true)

        _ = try await finishTask.value
        try await Task.sleep(nanoseconds: 1_000_000)
        let partialSnapshot = await partials.snapshot()
        XCTAssertEqual(partialSnapshot, ["please send the latest deck"])
    }

    func test_liveTranscription_commitsWindowWhenAppleDramaticallyShortensAfterPause() async throws {
        // Apple sometimes silently starts a new window without isFinal, and the first
        // word may be the same (e.g., both utterances start with "I"). The dramatic word
        // count drop (< 40% of current) is the reliable signal in that case.
        let factory = StubSessionFactory()
        let transcriber = Transcriber(
            authorizationProvider: { .authorized },
            sessionFactory: { factory.makeSession(onUpdate: $0) }
        )
        let partials = PartialSink()

        try await transcriber.startLiveTranscription { text in
            Task { await partials.append(text) }
        }
        // First window grows to 7 words
        factory.session?.emit(text: "I think we should send the deck", isFinal: false)
        // Apple starts a new window — same first word "I", but drops to 1 word (ratio 1/7 = 0.14 < 0.4)
        factory.session?.emit(text: "I", isFinal: false)
        // Second window grows
        factory.session?.emit(text: "I need to review", isFinal: false)

        let finishTask = Task { try await transcriber.finishTranscription() }
        await Task.yield()
        factory.session?.emit(text: "I need to review", isFinal: true)

        let finalTranscript = try await finishTask.value
        try await Task.sleep(nanoseconds: 1_000_000)
        XCTAssertEqual(finalTranscript, "I think we should send the deck I need to review")
    }

    func test_liveTranscription_deduplicatesRepeatedPrefixInExpandedIncomingUpdate() async throws {
        let factory = StubSessionFactory()
        let transcriber = Transcriber(
            authorizationProvider: { .authorized },
            sessionFactory: { factory.makeSession(onUpdate: $0) }
        )
        let partials = PartialSink()

        try await transcriber.startLiveTranscription { text in
            Task { await partials.append(text) }
        }

        factory.session?.emit(text: "please send the latest deck", isFinal: false)
        factory.session?.emit(
            text: "please send the latest deck please send the latest deck before the three pm sync",
            isFinal: false
        )

        let finishTask = Task { try await transcriber.finishTranscription() }
        await Task.yield()
        factory.session?.emit(
            text: "please send the latest deck before the three pm sync",
            isFinal: true
        )

        let finalTranscript = try await finishTask.value
        try await Task.sleep(nanoseconds: 1_000_000)
        let partialSnapshot = await partials.snapshot()
        XCTAssertEqual(
            partialSnapshot,
            ["please send the latest deck", "please send the latest deck before the three pm sync"]
        )
        XCTAssertEqual(finalTranscript, "please send the latest deck before the three pm sync")
    }

    func test_liveTranscription_deduplicatesRepeatedPrefixDespitePunctuationAndCaseChanges() async throws {
        let factory = StubSessionFactory()
        let transcriber = Transcriber(
            authorizationProvider: { .authorized },
            sessionFactory: { factory.makeSession(onUpdate: $0) }
        )
        let partials = PartialSink()

        try await transcriber.startLiveTranscription { text in
            Task { await partials.append(text) }
        }

        factory.session?.emit(text: "please send the latest deck", isFinal: false)
        factory.session?.emit(
            text: "Please send the latest deck, please send the latest deck before the three pm sync",
            isFinal: false
        )

        let finishTask = Task { try await transcriber.finishTranscription() }
        await Task.yield()
        factory.session?.emit(
            text: "please send the latest deck before the three pm sync",
            isFinal: true
        )

        let finalTranscript = try await finishTask.value
        try await Task.sleep(nanoseconds: 1_000_000)
        let partialSnapshot = await partials.snapshot()
        XCTAssertEqual(
            partialSnapshot,
            ["please send the latest deck", "please send the latest deck before the three pm sync"]
        )
        XCTAssertEqual(finalTranscript, "please send the latest deck before the three pm sync")
    }

    func test_startLiveTranscriptionRequiresSpeechAuthorization() async {
        let transcriber = Transcriber(
            authorizationProvider: { .denied },
            sessionFactory: { _ in fatalError("Session factory should not be called.") }
        )

        do {
            try await transcriber.startLiveTranscription { _ in }
            XCTFail("Expected authorization failure.")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                TranscriberError.speechRecognitionNotAuthorized.localizedDescription
            )
        }
    }

    private func makeBuffer() -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)!
        buffer.frameLength = 1
        buffer.floatChannelData?.pointee[0] = 0.25
        return buffer
    }
}
