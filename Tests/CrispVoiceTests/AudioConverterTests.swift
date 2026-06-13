import AVFoundation
import XCTest
@testable import CrispVoice

final class AudioConverterTests: XCTestCase {
    func test_convert_producesMono16kFloats_fromStereo48kBuffer() throws {
        let inFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let frames = AVAudioFrameCount(48_000)
        let buffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: frames)!
        buffer.frameLength = frames

        let converter = AudioConverter()
        let out = try converter.toWhisperFrames(buffer)

        XCTAssertGreaterThan(out.count, 15_000)
        XCTAssertLessThan(out.count, 17_000)
    }
}
