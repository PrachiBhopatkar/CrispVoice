import AVFoundation

struct AudioConverter {
    enum ConvertError: Error {
        case formatUnavailable
        case conversionFailed
    }

    func toWhisperFrames(_ input: AVAudioPCMBuffer) throws -> [Float] {
        guard let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            throw ConvertError.formatUnavailable
        }

        guard let converter = AVAudioConverter(from: input.format, to: outFormat) else {
            throw ConvertError.conversionFailed
        }

        let ratio = outFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else {
            throw ConvertError.conversionFailed
        }

        var consumed = false
        var convertError: NSError?
        converter.convert(to: output, error: &convertError) { _, status in
            if consumed {
                status.pointee = .endOfStream
                return nil
            }

            consumed = true
            status.pointee = .haveData
            return input
        }

        if let convertError {
            throw convertError
        }

        guard let channel = output.floatChannelData?[0] else {
            throw ConvertError.conversionFailed
        }

        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}
