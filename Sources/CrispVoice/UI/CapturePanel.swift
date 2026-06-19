import AppKit
import SwiftUI

/// A floating, non-activating panel that hosts SwiftUI content over the
/// current app WITHOUT stealing key focus from Slack.
final class CapturePanel<Content: View>: NSPanel {
    init(content: Content) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 220),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        contentView = NSHostingView(rootView: content)
        positionTopCenter()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private func positionTopCenter() {
        guard let screen = NSScreen.main else { return }
        let f = screen.visibleFrame
        setFrameOrigin(NSPoint(x: f.midX - frame.width / 2, y: f.maxY - frame.height - 80))
    }

    func present() { orderFrontRegardless() }
    func dismiss() { orderOut(nil) }
}
