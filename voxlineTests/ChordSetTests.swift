// voxlineTests/ChordSetTests.swift
import Foundation
import Testing
@testable import voxline

@Suite struct ChordSetTests {

    private let chords = ChordSet.default

    @Test func default_pairs_the_default_dictation_chord_with_the_default_command_chord() {
        #expect(chords.dictation == .default)
        #expect(chords.command == .defaultCommand)
    }

    @Test func kind_matching_returns_dictation_for_the_dictation_keys() {
        #expect(chords.kind(matching: HotkeyChord.default.keys) == .dictation)
    }

    @Test func kind_matching_returns_command_for_the_command_keys() {
        #expect(chords.kind(matching: HotkeyChord.defaultCommand.keys) == .command)
    }

    @Test func kind_matching_is_nil_for_a_single_shared_key() {
        #expect(chords.kind(matching: [.leftShift]) == nil)
    }

    @Test func kind_matching_is_nil_for_a_superset_of_a_chord() {
        #expect(chords.kind(matching: HotkeyChord.default.keys.union([.leftCommand])) == nil)
    }

    @Test func kind_matching_prefers_dictation_when_both_chords_are_equal() {
        let tied = ChordSet(dictation: .default, command: .default)
        #expect(tied.kind(matching: HotkeyChord.default.keys) == .dictation)
    }

    @Test func strict_subset_is_true_for_a_key_shared_by_both_chords() {
        #expect(chords.isStrictSubsetOfAny([.leftShift]))
    }

    @Test func strict_subset_is_true_for_a_key_in_only_one_chord() {
        #expect(chords.isStrictSubsetOfAny([.leftControl]))
        #expect(chords.isStrictSubsetOfAny([.leftOption]))
    }

    @Test func strict_subset_is_false_for_a_key_in_no_chord() {
        #expect(!chords.isStrictSubsetOfAny([.leftCommand]))
    }

    @Test func strict_subset_is_false_for_the_empty_set() {
        #expect(!chords.isStrictSubsetOfAny([]))
    }

    @Test func strict_subset_is_false_for_a_full_chord() {
        #expect(!chords.isStrictSubsetOfAny(HotkeyChord.default.keys))
        #expect(!chords.isStrictSubsetOfAny(HotkeyChord.defaultCommand.keys))
    }

    @Test func command_off_ignores_the_default_command_keys() {
        let off = ChordSet(dictation: .default, command: nil)
        #expect(off.kind(matching: HotkeyChord.defaultCommand.keys) == nil)
        #expect(off.allKeys.count == 2)
        #expect(off.entries.map(\.kind) == [.dictation])
        #expect(off.chord(for: .command) == nil)
    }

    @Test func chord_for_kind_returns_each_chord() {
        #expect(chords.chord(for: .dictation) == .default)
        #expect(chords.chord(for: .command) == .defaultCommand)
    }

    @Test func entries_list_dictation_first() {
        #expect(chords.entries.map(\.kind) == [.dictation, .command])
    }

    @Test func all_keys_unions_both_chords() {
        #expect(chords.allKeys == [.leftShift, .leftControl, .leftOption])
    }

    @Test func families_of_default_are_shift_control_and_option() {
        #expect(chords.families == [.shift, .control, .option])
    }
}
