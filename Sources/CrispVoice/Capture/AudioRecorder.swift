import AVFoundation

/// Captures microphone audio while recording, then returns whisper-ready frames.
final class AudioRecorder {
    private let engine = AVAudioEngine()
    private let converter = AudioConverter()
    private let lock = NSLock()
    private var collected: [Float] = []
    private(set) var isRecording = false

    func start() throws {
        guard !isRecording else { return }

        lock.lock()
        collected.removeAll()
        lock.unlock()

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            do {
                let frames = try self.converter.toWhisperFrames(buffer)
                self.lock.lock()
                self.collected.append(contentsOf: frames)
                self.lock.unlock()
            } catch {
                NSLog("CrispVoice: audio conversion failed: \(error.localizedDescription)")
            }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        isRecording = true
    }

    /// Stops capture and returns the full 16 kHz mono float buffer.
    func stop() -> [Float] {
        guard isRecording else {
            lock.lock()
            let snapshot = collected
            lock.unlock()
            return snapshot
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        lock.lock()
        let snapshot = collected
        lock.unlock()
        return snapshot
    }
}
