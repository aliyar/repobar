import AppKit
import Carbon.HIToolbox
import OSLog

/// One system-wide keyboard shortcut, registered through Carbon's hot key API.
///
/// Carbon is used on purpose: it needs no Accessibility permission, which
/// `NSEvent.addGlobalMonitorForEvents` would, and it keeps working while another
/// app is frontmost — the whole point of the shortcut for an accessory app.
@MainActor
final class GlobalHotKey {
    /// A recorded shortcut. `keyCode` is a virtual key code, `modifiers` are Cocoa flags.
    nonisolated struct Shortcut: Equatable, Sendable {
        var keyCode: UInt32
        /// `NSEvent.ModifierFlags.rawValue`, narrowed to the device-independent ones.
        var modifiers: UInt

        var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

        /// A shortcut without at least one of command/option/control would swallow typing.
        var isValid: Bool { !flags.intersection([.command, .option, .control]).isEmpty }

        /// What a fresh install starts with. A system-wide hot key shadows the frontmost
        /// app's own menu shortcut, so this avoids the busy combinations: ⌘R and ⇧⌘R are
        /// reload everywhere, and ⌥⌘R is taken in terminals. ⌃⌘ is comparatively quiet.
        static let suggested = Shortcut(
            keyCode: UInt32(kVK_ANSI_R),
            modifiers: NSEvent.ModifierFlags([.control, .command]).rawValue
        )

        var displayString: String {
            var text = ""
            if flags.contains(.control) { text += "⌃" }
            if flags.contains(.option) { text += "⌥" }
            if flags.contains(.shift) { text += "⇧" }
            if flags.contains(.command) { text += "⌘" }
            return text + KeyCodeNames.name(for: keyCode)
        }
    }

    var onPress: (() -> Void)?

    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private static let signature = FourCharCode(0x52_42_48_4B) // 'RBHK'
    private static var active: GlobalHotKey?

    init() {
        Self.active = self
    }

    // No deinit: this object lives for the whole run inside AppDependencies, and the
    // Carbon registration is torn down by the system when the process exits.

    /// Registers `shortcut`, replacing whatever was registered before. Passing nil just unregisters.
    /// Returns false when the combination is already taken by another application.
    @discardableResult
    func register(_ shortcut: Shortcut?) -> Bool {
        unregister()
        guard let shortcut, shortcut.isValid else { return true }

        installHandlerIfNeeded()
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: 1)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            Self.carbonModifiers(from: shortcut.flags),
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else {
            Log.ui.notice("hot key \(shortcut.displayString, privacy: .public) could not be registered (status \(status))")
            return false
        }
        reference = ref
        return true
    }

    func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        reference = nil
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ -> OSStatus in
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, id.signature == GlobalHotKey.signature else { return OSStatus(eventNotHandledErr) }
            Task { @MainActor in GlobalHotKey.active?.onPress?() }
            return noErr
        }, 1, &spec, nil, &handler)
    }

    /// Cocoa modifier flags → the Carbon bitfield `RegisterEventHotKey` expects.
    private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        return carbon
    }
}

/// Virtual key code → the label shown in Settings.
nonisolated enum KeyCodeNames {
    private static let named: [UInt32: String] = [
        UInt32(kVK_Return): "↩", UInt32(kVK_Tab): "⇥", UInt32(kVK_Space): "Space",
        UInt32(kVK_Delete): "⌫", UInt32(kVK_Escape): "⎋", UInt32(kVK_ForwardDelete): "⌦",
        UInt32(kVK_LeftArrow): "←", UInt32(kVK_RightArrow): "→",
        UInt32(kVK_UpArrow): "↑", UInt32(kVK_DownArrow): "↓",
        UInt32(kVK_Home): "↖", UInt32(kVK_End): "↘",
        UInt32(kVK_PageUp): "⇞", UInt32(kVK_PageDown): "⇟",
        UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3", UInt32(kVK_F4): "F4",
        UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6", UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8",
        UInt32(kVK_F9): "F9", UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
    ]

    static func name(for keyCode: UInt32) -> String {
        if let named = named[keyCode] { return named }
        if let character = characterFromLayout(keyCode) { return character.uppercased() }
        return "Key \(keyCode)"
    }

    /// Asks the current keyboard layout what this key produces, so an AZERTY user
    /// sees their own letters rather than a QWERTY translation.
    private static func characterFromLayout(_ keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = data.withUnsafeBytes { buffer -> OSStatus in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return OSStatus(paramErr) }
            return UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                                  UInt32(LMGetKbdType()), UInt32(kUCKeyTranslateNoDeadKeysBit),
                                  &deadKeys, characters.count, &length, &characters)
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: characters, count: length)
    }
}
