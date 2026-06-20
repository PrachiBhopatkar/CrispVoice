import AppKit
import CoreGraphics

/// Inserts text into the frontmost app by temporarily replacing the clipboard
/// and synthesizing Command-V, then restoring prior clipboard contents.
/// Requires Accessibility permission to post events to other apps.
final class Inserter {
    private let pasteboard: Pasteboard
    private let vKeyCode: CGKeyCode = 0x09

    init(pasteboard: Pasteboard = Pasteboard()) {
        self.pasteboard = pasteboard
    }

    func insert(_ text: String) {
        pasteboard.withTemporaryString(text) {
            synthesizeCommandV()
            // Slack's compose box can consume the clipboard asynchronously after
            // regaining focus, so keep the temporary value around a bit longer.
            usleep(500_000)
        }
    }

    private func synthesizeCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true)
        down?.flags = .maskCommand

        let up = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        up?.flags = .maskCommand

        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
