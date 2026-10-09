import Foundation
import Testing
@testable import voxline

@Suite struct KeyComboValidatorTests {

    private let noTyping: KeyComboValidator.Translator = { _, _ in nil }

    private func validate(
        _ combo: KeyCombo,
        others: [KeyCombo] = [],
        chords: ChordSet = .default,
        translate: KeyComboValidator.Translator? = nil
    ) -> KeyComboValidator.Verdict {
        KeyComboValidator.validate(combo, others: others, chords: chords, translate: translate ?? noTyping)
    }

    @Test func option_digit_is_ok() {
        #expect(validate(KeyCombo(keyCode: 18, modifiers: .option)) == .ok)
    }

    @Test func no_modifiers_is_rejected() {
        #expect(validate(KeyCombo(keyCode: 18, modifiers: [])) == .rejected("Use ⌘, ⌥, or ⌃ in the shortcut."))
    }

    @Test func shift_alone_is_rejected() {
        #expect(validate(KeyCombo(keyCode: 18, modifiers: .shift)) == .rejected("Use ⌘, ⌥, or ⌃ in the shortcut."))
    }

    @Test func escape_is_reserved() {
        #expect(validate(KeyCombo(keyCode: KeyCombo.escapeKeyCode, modifiers: .command))
                == .rejected("Esc is reserved for cancelling."))
    }

    @Test func duplicate_of_another_preset_is_rejected() {
        let combo = KeyCombo(keyCode: 19, modifiers: .option)
        let other = KeyCombo(keyCode: 18, modifiers: .option)
        #expect(validate(combo, others: [other, combo]) == .rejected("Another preset already uses this shortcut."))
    }

    @Test func combo_covering_the_command_chord_is_rejected() {
        #expect(validate(KeyCombo(keyCode: 18, modifiers: [.shift, .option]))
                == .rejected("⇧⌥ is your command hotkey"))
    }

    @Test func combo_covering_the_dictation_chord_is_rejected() {
        #expect(validate(KeyCombo(keyCode: 18, modifiers: [.shift, .control]))
                == .rejected("⇧⌃ is your dictation hotkey"))
    }

    @Test func combo_with_extra_modifiers_still_covers_the_chord() {
        #expect(validate(KeyCombo(keyCode: 18, modifiers: [.shift, .option, .command]))
                == .rejected("⇧⌥ is your command hotkey"))
    }

    @Test func chord_name_follows_the_chord_key_order() {
        let chords = ChordSet(
            dictation: HotkeyChord(modifierA: .leftControl, modifierB: .rightShift),
            command: nil
        )
        #expect(validate(KeyCombo(keyCode: 18, modifiers: [.shift, .control]), chords: chords)
                == .rejected("⌃⇧ is your dictation hotkey"))
    }

    @Test func same_family_chord_names_the_family_once() {
        let chords = ChordSet(
            dictation: HotkeyChord(modifierA: .leftShift, modifierB: .rightShift),
            command: nil
        )
        #expect(validate(KeyCombo(keyCode: 18, modifiers: [.shift, .option]), chords: chords)
                == .rejected("⇧ is your dictation hotkey"))
    }

    @Test func missing_command_chord_leaves_the_dictation_chord_only() {
        var chords = ChordSet.default
        chords.command = nil
        #expect(validate(KeyCombo(keyCode: 18, modifiers: [.shift, .option]), chords: chords) == .ok)
    }

    @Test func typed_character_warns() {
        let combo = KeyCombo(keyCode: 19, modifiers: .option)
        let verdict = validate(combo, translate: { _, _ in "™" })
        #expect(verdict == .warning("⌥2 types “™” on your keyboard. Voxline will capture it everywhere."))
    }

    @Test func command_only_combo_warns_as_a_common_app_shortcut() {
        #expect(validate(KeyCombo(keyCode: 8, modifiers: .command))
                == .warning("⌘C is a common app shortcut. Voxline will capture it everywhere."))
    }

    @Test func command_shift_combo_warns_with_its_own_display_string() {
        #expect(validate(KeyCombo(keyCode: 21, modifiers: [.command, .shift]))
                == .warning("⇧⌘4 is a common app shortcut. Voxline will capture it everywhere."))
    }

    @Test(arguments: [
        ModifierFamilies([.command, .option]),
        [.command, .control],
        [.command, .option, .control],
        .option,
        .control,
    ])
    func combos_with_option_or_control_are_not_app_shortcut_warnings(modifiers: ModifierFamilies) {
        #expect(validate(KeyCombo(keyCode: 8, modifiers: modifiers)) == .ok)
    }

    @Test func app_shortcut_warning_wins_over_a_typed_character() {
        #expect(validate(KeyCombo(keyCode: 8, modifiers: .command), translate: { _, _ in "c" })
                == .warning("⌘C is a common app shortcut. Voxline will capture it everywhere."))
    }

    @Test func rejection_wins_over_the_app_shortcut_warning() {
        let combo = KeyCombo(keyCode: 8, modifiers: .command)
        #expect(validate(combo, others: [combo]) == .rejected("Another preset already uses this shortcut."))
    }

    @Test func translator_receives_the_combo() {
        let seen = CallBox<(UInt16, ModifierFamilies)?>(nil)
        _ = validate(KeyCombo(keyCode: 19, modifiers: [.option, .command]), translate: { code, mods in
            seen.value = (code, mods)
            return nil
        })
        #expect(seen.value?.0 == 19)
        #expect(seen.value?.1 == [.option, .command])
    }

    @Test func whitespace_only_output_is_ok() {
        #expect(validate(KeyCombo(keyCode: 49, modifiers: .option), translate: { _, _ in " " }) == .ok)
    }

    @Test func control_character_only_output_is_ok() {
        #expect(validate(KeyCombo(keyCode: 36, modifiers: .option), translate: { _, _ in "\u{1B}\n" }) == .ok)
    }

    @Test func empty_output_is_ok() {
        #expect(validate(KeyCombo(keyCode: 18, modifiers: .option), translate: { _, _ in "" }) == .ok)
    }

    @Test func output_with_one_printable_scalar_among_whitespace_warns() {
        let verdict = validate(KeyCombo(keyCode: 19, modifiers: .option), translate: { _, _ in " ™" })
        #expect(verdict == .warning("⌥2 types “ ™” on your keyboard. Voxline will capture it everywhere."))
    }

    @Test func rejection_wins_over_the_typed_character_warning() {
        let combo = KeyCombo(keyCode: 19, modifiers: .option)
        #expect(validate(combo, others: [combo], translate: { _, _ in "™" })
                == .rejected("Another preset already uses this shortcut."))
    }

    @Test func no_modifier_rejection_wins_over_escape() {
        #expect(validate(KeyCombo(keyCode: KeyCombo.escapeKeyCode, modifiers: []))
                == .rejected("Use ⌘, ⌥, or ⌃ in the shortcut."))
    }

    @Test func translator_is_not_consulted_for_a_rejected_combo() {
        let called = CallBox(false)
        _ = validate(KeyCombo(keyCode: 18, modifiers: []), translate: { _, _ in
            called.value = true
            return "x"
        })
        #expect(called.value == false)
    }

    @MainActor @Test func live_translator_does_not_crash() {
        _ = KeyComboValidator.liveTranslator(18, .option)
        _ = KeyComboValidator.liveTranslator(19, [.option, .shift])
        #expect(KeyComboValidator.liveTranslator(18, .command) == nil)
        #expect(KeyComboValidator.liveTranslator(18, .control) == nil)
    }
}

private final class CallBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ initial: T) { stored = initial }
    var value: T {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
