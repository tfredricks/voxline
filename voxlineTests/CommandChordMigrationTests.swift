// voxlineTests/CommandChordMigrationTests.swift
import Foundation
import Testing
@testable import voxline

@Suite struct CommandChordMigrationTests {

    private let d = HotkeyChord.default

    @Test func absent_value_gets_the_default_command_chord() {
        #expect(CommandChordMigration.commandChord(dictation: d, stored: nil) == .defaultCommand)
    }

    @Test func unparseable_value_is_treated_as_the_shipped_default() {
        #expect(CommandChordMigration.commandChord(dictation: d, stored: "garbage") == .defaultCommand)
    }

    @Test func a_modifier_outside_the_dictation_chord_pairs_with_dictation_modifier_a() {
        let expected = HotkeyChord(modifierA: .leftShift, modifierB: .rightCommand)
        #expect(CommandChordMigration.commandChord(dictation: d, stored: "rightCommand") == expected)
    }

    @Test func the_shipped_default_modifier_yields_the_default_command_chord() {
        #expect(CommandChordMigration.commandChord(dictation: d, stored: "leftOption") == .defaultCommand)
    }

    @Test func a_modifier_that_is_dictation_modifier_a_is_treated_as_off() {
        #expect(CommandChordMigration.commandChord(dictation: d, stored: "leftShift") == .defaultCommand)
    }

    @Test func a_modifier_that_is_dictation_modifier_b_is_treated_as_off() {
        #expect(CommandChordMigration.commandChord(dictation: d, stored: "leftControl") == .defaultCommand)
    }

    @Test func off_gets_the_default_command_chord() {
        #expect(CommandChordMigration.commandChord(dictation: d, stored: "off") == .defaultCommand)
    }

    @Test func off_with_dictation_equal_to_the_default_command_chord_turns_command_mode_off() {
        let dictation = HotkeyChord(modifierA: .leftShift, modifierB: .leftOption)
        #expect(CommandChordMigration.commandChord(dictation: dictation, stored: "off") == nil)
    }

    @Test func absent_value_with_dictation_equal_to_the_default_command_chord_turns_command_mode_off() {
        let dictation = HotkeyChord(modifierA: .leftShift, modifierB: .leftOption)
        #expect(CommandChordMigration.commandChord(dictation: dictation, stored: nil) == nil)
    }

    @Test func dictation_equal_to_the_default_command_chord_in_swapped_order_still_turns_command_mode_off() {
        let dictation = HotkeyChord(modifierA: .leftOption, modifierB: .leftShift)
        #expect(CommandChordMigration.commandChord(dictation: dictation, stored: "off") == nil)
    }

    @Test func a_custom_dictation_chord_keeps_its_modifier_a() {
        let dictation = HotkeyChord(modifierA: .leftCommand, modifierB: .leftShift)
        let expected = HotkeyChord(modifierA: .leftCommand, modifierB: .leftOption)
        #expect(CommandChordMigration.commandChord(dictation: dictation, stored: "leftOption") == expected)
    }

    @Test func a_custom_dictation_chord_with_a_colliding_modifier_falls_back_to_the_default_command_chord() {
        let dictation = HotkeyChord(modifierA: .leftCommand, modifierB: .leftShift)
        #expect(CommandChordMigration.commandChord(dictation: dictation, stored: "leftShift") == .defaultCommand)
    }
}
