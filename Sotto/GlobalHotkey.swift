import Carbon.HIToolbox

/// A system-wide hotkey via Carbon `RegisterEventHotKey`. Unlike an `NSEvent` global key monitor, this needs no
/// Accessibility or Input Monitoring grant. Carbon delivers the event on the main thread.
final class GlobalHotkey {
    private let action: () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    /// Returns nil (and logs why) if the handler can't be installed or another app already owns the combination.
    init?(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        self.action = action

        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        var status = InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            Unmanaged<GlobalHotkey>.fromOpaque(userData).takeUnretainedValue().action()
            return noErr
        }, 1, &pressed, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)

        if status == noErr {
            let id = EventHotKeyID(signature: OSType(0x534F_5454), id: 1) // 'SOTT'
            status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &hotKeyRef)
        }
        guard status == noErr else {
            print("GlobalHotkey: registration failed (OSStatus \(status)); another app may already use this shortcut")
            return nil // deinit removes whatever was installed
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
