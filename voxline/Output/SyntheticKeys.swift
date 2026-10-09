// voxline/Output/SyntheticKeys.swift
import Carbon.HIToolbox
import CoreGraphics

/// The only place voxline creates and posts key events. Every event is
/// tagged so voxline's own taps can ignore it.
enum SyntheticKeys {
    /// "voxl" as a 32-bit tag in `eventSourceUserData`.
    static let tag: Int64 = 0x766F786C

    static let copyFallbackKeyCode: CGKeyCode = 8
    static let pasteFallbackKeyCode: CGKeyCode = 9
    static let rightArrowKeyCode: CGKeyCode = 124

    static func isTagged(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == tag
    }

    /// Key down + key up with exactly `flags`, both tagged. Posted from
    /// `.hidSystemState`, as a physical key press is: some terminals with an
    /// autocomplete suggestion showing drop a Cmd+V posted from
    /// `.combinedSessionState`.
    static func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags) {
        post(keyEvents(keyCode, flags: flags, source: CGEventSource(stateID: .hidSystemState)))
    }

    /// Must be called on the main thread (Text Input Sources asserts otherwise).
    static func postCopy() {
        postKey(shortcutKeyCode(typing: "c") ?? copyFallbackKeyCode, flags: .maskCommand)
    }

    /// Must be called on the main thread (Text Input Sources asserts otherwise).
    static func postPaste() {
        postKey(shortcutKeyCode(typing: "v") ?? pasteFallbackKeyCode, flags: .maskCommand)
    }

    static func postRightArrow() {
        postKey(rightArrowKeyCode, flags: [])
    }

    /// Backspace, which deletes a non-empty selection in any text view.
    /// Called on the main thread like every insert keystroke; `kVK_Delete` is
    /// the same key on every layout, so it needs no Text Input Sources lookup.
    static func postDelete() {
        postKey(CGKeyCode(kVK_Delete), flags: [])
    }

    /// One tagged keyDown/keyUp pair carrying `units` via
    /// `keyboardSetUnicodeString`, from `.combinedSessionState`. Callers keep
    /// each chunk to at most 20 UTF-16 units (`TypingChunker`'s `maxUnits`);
    /// only a single grapheme longer than that may exceed it, alone in its chunk.
    static func typeChunk(_ units: [UInt16]) {
        post(chunkEvents(units, source: CGEventSource(stateID: .combinedSessionState)))
    }

    /// A tagged flagsChanged with empty flags, which tells the focused app
    /// that no modifier is held.
    static func forceClearModifiers() {
        guard let event = forceClearEvent(source: CGEventSource(stateID: .hidSystemState)) else { return }
        post([event])
    }

    /// The tagged down/up pair `postKey` posts; empty when either event
    /// cannot be created, so a key is never left down.
    static func keyEvents(_ keyCode: CGKeyCode, flags: CGEventFlags, source: CGEventSource?) -> [CGEvent] {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return [] }
        down.flags = flags
        up.flags = flags
        return [tagged(down), tagged(up)]
    }

    /// The tagged down/up pair `typeChunk` posts; empty for empty `units`,
    /// which would otherwise type the bare keycode.
    static func chunkEvents(_ units: [UInt16], source: CGEventSource?) -> [CGEvent] {
        guard !units.isEmpty,
              let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        else { return [] }
        var chunk = units
        chunk.withUnsafeMutableBufferPointer { buffer in
            down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
        }
        return [tagged(down), tagged(up)]
    }

    static func forceClearEvent(source: CGEventSource?) -> CGEvent? {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return nil }
        event.flags = []
        event.type = .flagsChanged
        return tagged(event)
    }

    /// UCKeyTranslate's `modifierKeyState` with Command held: the Carbon
    /// modifier mask shifted down a byte.
    static let commandModifierKeyState = UInt32((cmdKey >> 8) & 0xFF)

    /// Keycode of the ⌘ shortcut for `character` on `layout` (the current
    /// keyboard layout when nil), resolved with Command held: a layout that
    /// switches keys under ⌘, such as "Dvorak – QWERTY ⌘", puts ⌘C and ⌘V
    /// elsewhere than its unmodified C and V.
    /// Must be called on the main thread (Text Input Sources asserts otherwise).
    static func shortcutKeyCode(typing character: String, layout: TISInputSource? = nil) -> CGKeyCode? {
        keyCode(typing: character, modifierKeyState: commandModifierKeyState, layout: layout)
    }

    /// Keycode that types `character` with `modifierKeyState` on `layout`
    /// (the current keyboard layout when nil), via UCKeyTranslate over
    /// keycodes 0..<128 with `kUCKeyActionDisplay`.
    /// Must be called on the main thread (Text Input Sources asserts otherwise).
    static func keyCode(typing character: String, modifierKeyState: UInt32 = 0, layout: TISInputSource? = nil) -> CGKeyCode? {
        let target = character.lowercased()
        guard
            let source = layout ?? TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            let layoutDataPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else {
            return nil
        }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutDataPointer).takeUnretainedValue()
        return withExtendedLifetime((source, layoutData)) { () -> CGKeyCode? in
            guard let bytes = CFDataGetBytePtr(layoutData) else { return nil }
            let keyboardLayout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
            let keyboardType = UInt32(LMGetKbdType())
            for keyCode in UInt16(0)..<UInt16(128) {
                var deadKeyState: UInt32 = 0
                var actualLength = 0
                var chars = [UniChar](repeating: 0, count: 8)
                let status = chars.withUnsafeMutableBufferPointer { buffer in
                    UCKeyTranslate(
                        keyboardLayout,
                        keyCode,
                        UInt16(kUCKeyActionDisplay),
                        modifierKeyState,
                        keyboardType,
                        OptionBits(kUCKeyTranslateNoDeadKeysMask),
                        &deadKeyState,
                        buffer.count,
                        &actualLength,
                        buffer.baseAddress
                    )
                }
                guard status == noErr, actualLength > 0 else { continue }
                if String(utf16CodeUnits: chars, count: actualLength).lowercased() == target {
                    return CGKeyCode(keyCode)
                }
            }
            return nil
        }
    }

    private static func tagged(_ event: CGEvent) -> CGEvent {
        event.setIntegerValueField(.eventSourceUserData, value: tag)
        return event
    }

    private static func post(_ events: [CGEvent]) {
        for event in events { event.post(tap: .cghidEventTap) }
    }
}
