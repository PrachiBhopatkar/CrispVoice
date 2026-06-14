import AppKit
import OSLog

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(subsystem: "com.crispvoice.app", category: "debug")
    private var statusItem: NSStatusItem!
    private var titleMenuItem: NSMenuItem!
    private let hotkeys = HotkeyManager()
    private let inserter = Inserter()
    private var debugRecorder: AudioRecorder?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🎙️"
        let menu = NSMenu()
        let titleMenuItem = NSMenuItem(title: "CrispVoice", action: nil, keyEquivalent: "")
        self.titleMenuItem = titleMenuItem
        menu.addItem(titleMenuItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        let recorder = AudioRecorder()
        self.debugRecorder = recorder
        hotkeys.register { [weak self] in
            guard let self else { return }
            if recorder.isRecording {
                let frames = recorder.stop()
                self.statusItem.button?.title = "🎙️"
                self.logger.info("CrispVoice: captured \(frames.count, privacy: .public) frames")
                let modelURL = Bundle.main.url(forResource: "ggml-base", withExtension: "bin")
                    ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath + "/Models/ggml-base.bin")
                let transcriber = Transcriber(modelURL: modelURL)
                Task { [weak self] in
                    guard let self else { return }
                    do {
                        let text = try await transcriber.transcribe(frames)
                        await MainActor.run {
                            self.titleMenuItem.title = text.isEmpty ? "<empty transcript>" : text
                        }
                        self.logger.info("CrispVoice: transcript ready")
                    } catch {
                        await MainActor.run {
                            self.titleMenuItem.title = "<transcription failed>"
                        }
                        self.logger.error("CrispVoice: transcription failed: \(error.localizedDescription, privacy: .public)")
                    }
                }
            } else {
                do {
                    try recorder.start()
                    self.statusItem.button?.title = "REC"
                    self.logger.info("CrispVoice: recording…")
                } catch {
                    self.logger.error("CrispVoice: recording failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }
}
