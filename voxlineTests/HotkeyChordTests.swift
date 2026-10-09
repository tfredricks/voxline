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

    @Test func default_command_is_left_shift_plus_left_option() {
        #expect(HotkeyChord.defaultCommand.modifierA == .leftShift)
        #expect(HotkeyChord.defaultCommand.modifierB == .leftOption)
    }

    @Test func keys_is_the_set_of_both_modifiers() {
        #expect(HotkeyChord.default.keys == [.leftShift, .leftControl])
    }

    @Test func families_is_the_side_agnostic_union() {
        #expect(HotkeyChord.default.families == [.shift, .control])
        #expect(HotkeyChord(modifierA: .leftShift, modifierB: .rightShift).families == .shift)
    }

    @Test func chord_is_hashable_by_value() {
        let a = HotkeyChord(modifierA: .leftShift, modifierB: .leftControl)
        #expect(Set([a, .default]).count == 1)
    }

}
