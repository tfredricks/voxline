// voxlineTests/HotkeyChordTests.swift
import CoreGraphics
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

    @Test func chord_matches_when_both_modifiers_down() {
        // HotkeyChord.default = leftControl (0x1) + leftOption (0x20)
        let c = HotkeyChord.default
        let bothDown    = CGEventFlags(rawValue: 0x00000021) // leftControl | leftOption
        let onlyModA    = CGEventFlags(rawValue: 0x00000001) // leftControl only
        let onlyModB    = CGEventFlags(rawValue: 0x00000020) // leftOption only
        let neitherDown = CGEventFlags(rawValue: 0x00000000)

        #expect(c.matches(flags: bothDown)    == true)   // (modA on, modB on)
        #expect(c.matches(flags: onlyModA)    == false)  // (modA on, modB off)
        #expect(c.matches(flags: onlyModB)    == false)  // (modA off, modB on)
        #expect(c.matches(flags: neitherDown) == false)  // (modA off, modB off)

        // Non-default chord: leftCommand (0x8) + leftShift (0x2)
        // Proves matches() actually consults self.modifierA / self.modifierB.
        let cmdShift    = HotkeyChord(modifierA: .leftCommand, modifierB: .leftShift)
        let cmdShiftOn  = CGEventFlags(rawValue: 0x0000000A) // leftCommand | leftShift
        #expect(cmdShift.matches(flags: cmdShiftOn) == true)
        #expect(cmdShift.matches(flags: bothDown)   == false) // leftControl|leftOption ≠ leftCommand|leftShift
    }
}
