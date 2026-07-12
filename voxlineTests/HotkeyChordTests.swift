// voxlineTests/HotkeyChordTests.swift
import Testing
import Foundation
import CoreGraphics
@testable import voxline

@Suite struct HotkeyChordTests {

    @Test func default_is_left_shift_plus_left_control() {
        let c = HotkeyChord.default
        #expect(c.modifierA == .leftShift)
        #expect(c.modifierB == .leftControl)
    }

    @Test func display_name_lists_both_modifiers_in_order() {
        #expect(HotkeyChord.default.displayName == "Left Shift + Left Ctrl")
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

    @Test func modifier_isHeld_reads_device_mask_bit() {
        let optionFlags = CGEventFlags(rawValue: HotkeyChord.Modifier.leftOption.deviceMaskBit)
        #expect(HotkeyChord.Modifier.leftOption.isHeld(in: optionFlags) == true)
        #expect(HotkeyChord.Modifier.leftShift.isHeld(in: optionFlags) == false)
        #expect(HotkeyChord.Modifier.leftOption.isHeld(in: CGEventFlags(rawValue: 0)) == false)
    }

    @Test func command_conflict_warning_nil_when_off() {
        let chord = HotkeyChord(modifierA: .leftShift, modifierB: .leftControl)
        #expect(HotkeyChord.commandModifierConflictWarning(command: nil, chord: chord) == nil)
    }

    @Test func command_conflict_warning_fires_when_equal_to_a_chord_key() {
        let chord = HotkeyChord(modifierA: .leftShift, modifierB: .leftControl)
        let w = HotkeyChord.commandModifierConflictWarning(command: .leftShift, chord: chord)
        #expect(w != nil)
        #expect(w?.contains("hotkey") == true)
    }

    @Test func command_conflict_warning_fires_for_ctrl_option_voiceover_combo() {
        // chord holds Left Control; adding Left Option forms Ctrl+Option (VoiceOver).
        let chord = HotkeyChord(modifierA: .leftShift, modifierB: .leftControl)
        let w = HotkeyChord.commandModifierConflictWarning(command: .leftOption, chord: chord)
        #expect(w != nil)
        #expect(w?.contains("VoiceOver") == true)
    }

    @Test func command_conflict_warning_nil_for_safe_combo() {
        let chord = HotkeyChord(modifierA: .leftShift, modifierB: .leftControl)
        // Left Command doesn't collide and doesn't form Ctrl+Option.
        #expect(HotkeyChord.commandModifierConflictWarning(command: .leftCommand, chord: chord) == nil)
    }

}
