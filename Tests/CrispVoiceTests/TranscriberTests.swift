import AVFoundation
import XCTest
@testable import CrispVoice

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
        var partials: [String] = []

        try await transcriber.startLiveTranscription { partials.append($0) }
        transcriber.appendAudioBuffer(buffer)
        factory.session?.emit(text: "  hello there  ", isFinal: false)

        let finishTask = Task { try await transcriber.finishTranscription() }
        await Task.yield()
        XCTAssertEqual(factory.session?.appendedBufferCount, 1)
        XCTAssertEqual(factory.session?.didFinishAudio, true)

        factory.session?.emit(text: "  hello there world \n", isFinal: true)
        let finalTranscript = try await finishTask.value

        XCTAssertEqual(partials, ["hello there", "hello there world"])
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
