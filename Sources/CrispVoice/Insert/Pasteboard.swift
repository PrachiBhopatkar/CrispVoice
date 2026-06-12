import AppKit

/// Thin wrapper over NSPasteboard for temporary plain-text replacement.
final class Pasteboard {
    private let pb: NSPasteboard

    init(_ pb: NSPasteboard = .general) {
        self.pb = pb
    }

    func string() -> String? {
        pb.string(forType: .string)
    }

    func setString(_ value: String) {
        pb.clearContents()
        pb.setString(value, forType: .string)
    }

    /// Sets `value`, runs `body` (e.g. paste), then restores prior plain-text contents.
    func withTemporaryString(_ value: String, _ body: () -> Void) {
        let previous = pb.string(forType: .string)
        setString(value)
        body()
        if let previous {
            setString(previous)
        } else {
            pb.clearContents()
        }
    }
}
