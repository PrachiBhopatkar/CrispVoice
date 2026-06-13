import AppKit
import OSLog

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(subsystem: "com.crispvoice.app", category: "debug")
    private var statusItem: NSStatusItem!
    private let hotkeys = HotkeyManager()
    private let inserter = Inserter()
    private var debugRecorder: AudioRecorder?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🎙️"
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "CrispVoice", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        let recorder = AudioRecorder()
        self.debugRecorder = recorder
        hotkeys.register { [weak self] in
            guard let self else { return }
            if recorder.isRecording {
                let frames = recorder.stop()
                self.logger.info("CrispVoice: captured \(frames.count, privacy: .public) frames")
            } else {
                do {
                    try recorder.start()
                    self.logger.info("CrispVoice: recording…")
                } catch {
                    self.logger.error("CrispVoice: recording failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }
}
