import Foundation
import SwiftWhisper

/// Wraps whisper.cpp (via SwiftWhisper) for on-device transcription.
final class Transcriber {
    private let whisper: Whisper

    init(modelURL: URL) {
        self.whisper = Whisper(fromFileURL: modelURL)
    }

    /// Transcribes 16 kHz mono float frames into a single trimmed string.
    func transcribe(_ frames: [Float]) async throws -> String {
        let segments = try await whisper.transcribe(audioFrames: frames)
        return segments
            .map(\.text)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
