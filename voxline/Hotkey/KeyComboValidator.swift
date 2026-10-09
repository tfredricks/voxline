import Carbon.HIToolbox
import Foundation

/// Pure checks for a recorded preset shortcut. Rejections stop the recording;
/// the app-shortcut and typed-character warnings let the combo through so the
/// user can decide.
enum KeyComboValidator {

    enum Verdict: Equatable {
        case ok
        case warning(String)
        case rejected(String)
    }

    /// What `modifiers` + `keyCode` types on the current keyboard layout, or
    /// nil when it types nothing.
    typealias Translator = @Sendable (_ keyCode: UInt16, _ modifiers: ModifierFamilies) -> String?

    static func validate(
        _ combo: KeyCombo,
        others: [KeyCombo],
        chords: ChordSet,
        translate: Translator
    ) -> Verdict {
        if combo.modifiers.isDisjoint(with: [.command, .option, .control]) {
            return .rejected("Use ⌘, ⌥, or ⌃ in the shortcut.")
        }
        if combo.keyCode == KeyCombo.escapeKeyCode {
            return .rejected("Esc is reserved for cancelling.")
        }
        if others.contains(combo) {
            return .rejected("Another preset already uses this shortcut.")
        }
        for (kind, chord) in chords.entries where chord.families.isSubset(of: combo.modifiers) {
            let owner = kind == .dictation ? "dictation" : "command"
            return .rejected("\(chordSymbols(chord)) is your \(owner) hotkey")
        }
        if appShortcutModifiers.contains(combo.modifiers) {
            return .warning("\(combo.displayName) is a common app shortcut. Voxline will capture it everywhere.")
        }
        if let typed = translate(combo.keyCode, combo.modifiers), typesVisibleCharacter(typed) {
            return .warning("\(combo.displayName) types “\(typed)” on your keyboard. Voxline will capture it everywhere.")
        }
        return .ok
    }

    /// Modifier sets that apps use for their own menu shortcuts (⌘C, ⇧⌘4).
    /// Allowed, with a warning, since the preset takes them over everywhere.
    private static let appShortcutModifiers: [ModifierFamilies] = [.command, [.command, .shift]]

    private static let invisible = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)

    private static func typesVisibleCharacter(_ s: String) -> Bool {
        s.unicodeScalars.contains { !invisible.contains($0) }
    }

    /// The chord's families in the order the user picked its keys, so the
    /// default chords read "⇧⌃" and "⇧⌥".
    private static func chordSymbols(_ chord: HotkeyChord) -> String {
        var seen: ModifierFamilies = []
        var out = ""
        for modifier in [chord.modifierA, chord.modifierB] {
            let family = modifier.family
            guard seen.isDisjoint(with: family) else { continue }
            seen.formUnion(family)
            out += family.displayString
        }
        return out
    }

    /// Text Input Sources asserts the main thread, so call this from there.
    static let liveTranslator: Translator = { keyCode, modifiers in
        if !modifiers.isDisjoint(with: [.command, .control]) { return nil }

        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()

        var state: UInt32 = 0
        if modifiers.contains(.option) { state |= UInt32(optionKey >> 8) }
        if modifiers.contains(.shift)  { state |= UInt32(shiftKey >> 8) }

        return withExtendedLifetime((source, layoutData)) { () -> String? in
            guard let bytes = CFDataGetBytePtr(layoutData) else { return nil }
            var deadKeyState: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let status = bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout in
                UCKeyTranslate(
                    layout,
                    keyCode,
                    UInt16(kUCKeyActionDisplay),
                    state,
                    UInt32(LMGetKbdType()),
                    OptionBits(kUCKeyTranslateNoDeadKeysMask),
                    &deadKeyState,
                    chars.count,
                    &length,
                    &chars
                )
            }
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: chars, count: length)
        }
    }
}
