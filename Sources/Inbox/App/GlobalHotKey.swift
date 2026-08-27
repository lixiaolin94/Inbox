import AppKit
import Carbon.HIToolbox

/// System-wide ⌥Space summon (README 键盘表, PRD §13). One fixed hot key,
/// registered through Carbon's `RegisterEventHotKey` — the supported,
/// permission-free API that shortcut libraries wrap; wrapping it directly
/// keeps the zero-dependency rule. Registration is non-exclusive (options 0)
/// so a second running copy (smoke, debug build) cannot fail to register.
enum GlobalHotKey {
    private static var hotKeyRef: EventHotKeyRef?
    private static var handlerRef: EventHandlerRef?
    private static var onPress: (() -> Void)?

    static var isRegistered: Bool { hotKeyRef != nil }

    static func register(_ handler: @escaping () -> Void) {
        onPress = handler
        guard hotKeyRef == nil else { return }
        if handlerRef == nil {
            var eventType = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            )
            // The C callback cannot capture context; the single handler
            // lives in `onPress`.
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                GlobalHotKey.onPress?()
                return noErr
            }, 1, &eventType, nil, &handlerRef)
        }
        let hotKeyID = EventHotKeyID(signature: OSType(0x494E_4258), id: 1) // "INBX"
        RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    static func unregister() {
        guard let hotKeyRef else { return }
        UnregisterEventHotKey(hotKeyRef)
        Self.hotKeyRef = nil
        onPress = nil
    }
}
