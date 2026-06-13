import AppKit
import Carbon
import HotKey

/// Registers a single global hotkey and invokes a closure on key-down.
final class HotkeyManager {
    private var eventHandler: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?
    private var onTrigger: (() -> Void)?
    private let hotKeyID = EventHotKeyID(signature: 0x43525648, id: 1)

    deinit {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }

        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }

    /// Default: ⌃⌥C.
    func register(key: Key = .c, modifiers: NSEvent.ModifierFlags = [.control, .option], onTrigger: @escaping () -> Void) {
        self.onTrigger = onTrigger

        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }

        if eventHandler == nil {
            var eventHandler: EventHandlerRef?
            var eventSpec = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            )

            InstallEventHandler(
                GetEventDispatcherTarget(),
                { _, event, userData in
                    guard let userData else {
                        return OSStatus(eventNotHandledErr)
                    }

                    let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                    return manager.handle(event)
                },
                1,
                &eventSpec,
                UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
                &eventHandler
            )

            self.eventHandler = eventHandler
        }

        var hotKeyRef: EventHotKeyRef?
        let result = RegisterEventHotKey(
            key.carbonKeyCode,
            modifiers.carbonFlags,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &hotKeyRef
        )

        guard result == noErr else {
            return
        }

        self.hotKeyRef = hotKeyRef
    }

    private func handle(_ event: EventRef?) -> OSStatus {
        guard let event else {
            return OSStatus(eventNotHandledErr)
        }

        var eventHotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            UInt32(kEventParamDirectObject),
            UInt32(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &eventHotKeyID
        )

        guard status == noErr, eventHotKeyID.signature == hotKeyID.signature, eventHotKeyID.id == hotKeyID.id else {
            return OSStatus(eventNotHandledErr)
        }

        onTrigger?()
        return noErr
    }
}
