// voxlineTests/HotkeyChordTests.swift
import Testing
import Foundation
@testable import voxline

@Suite struct HotkeyChordTests {

    @Test func default_is_left_ctrl_plus_left_option() {
        let c = HotkeyChord.default
        #expect(c.modifierA == .leftControl)
        #expect(c.modifierB == .leftOption)
    }

    @Test func display_name_lists_both_modifiers_in_order() {
        #expect(HotkeyChord.default.displayName == "Left Ctrl + Left Option")
        let c = HotkeyChord(modifierA: .leftCommand, modifierB: .leftShift)
        #expect(c.displayName == "Left Cmd + Left Shift")
    }

    @Test func codable_round_trip() throws {
        let original = HotkeyChord(modifierA: .leftCommand, modifierB: .leftShift)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(HotkeyChord.self, from: data)
        #expect(decoded == original)
    }

    @Test func voiceover_chord_warning_fires_for_ctrl_option_combos() {
        let lcLo = HotkeyChord(modifierA: .leftControl, modifierB: .leftOption)
        let loLc = HotkeyChord(modifierA: .leftOption,  modifierB: .leftControl)
        let rcRo = HotkeyChord(modifierA: .rightControl, modifierB: .rightOption)
        let mixed = HotkeyChord(modifierA: .leftControl, modifierB: .rightOption)
        #expect(lcLo.conflictWarning != nil)
        #expect(loLc.conflictWarning != nil)
        #expect(rcRo.conflictWarning != nil)
        #expect(mixed.conflictWarning != nil)
    }

    @Test func no_warning_for_unrelated_chords() {
        let chord = HotkeyChord(modifierA: .leftCommand, modifierB: .leftShift)
        #expect(chord.conflictWarning == nil)
    }

}
