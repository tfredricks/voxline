// voxlineTests/KeyComboTests.swift
import CoreGraphics
import Foundation
import Testing
@testable import voxline

@Suite struct KeyComboTests {

    @Test func flags_ignore_caps_lock_fn_and_keypad() {
        let flags: CGEventFlags = [.maskAlternate, .maskAlphaShift, .maskSecondaryFn, .maskNumericPad]
        #expect(ModifierFamilies(flags: flags) == .option)
    }

    @Test func flags_map_each_generic_bit_to_its_family() {
        #expect(ModifierFamilies(flags: [.maskCommand, .maskShift]) == [.command, .shift])
        #expect(ModifierFamilies(flags: [.maskControl]) == .control)
        #expect(ModifierFamilies(flags: []) == [])
    }

    @Test func display_string_uses_mac_menu_order() {
        #expect(ModifierFamilies([.shift, .option]).displayString == "⌥⇧")
        #expect(ModifierFamilies([.command, .shift, .option, .control]).displayString == "⌃⌥⇧⌘")
        #expect(ModifierFamilies([]).displayString == "")
    }

    @Test func cg_flags_round_trip_through_init_flags() {
        let all: [ModifierFamilies] = [[], .command, .option, .control, .shift,
                                       [.command, .shift], [.command, .option, .control, .shift]]
        for families in all {
            #expect(ModifierFamilies(flags: families.cgFlags) == families)
        }
    }

    @Test func families_from_side_specific_modifiers() {
        #expect(ModifierFamilies(modifiers: [HotkeyChord.Modifier.leftShift, .rightShift, .leftCommand]) == [.shift, .command])
        #expect(ModifierFamilies(modifiers: [HotkeyChord.Modifier]()) == [])
    }

    @Test func every_side_maps_to_its_family() {
        #expect(HotkeyChord.Modifier.rightOption.family == .option)
        #expect(HotkeyChord.Modifier.leftOption.family == .option)
        #expect(HotkeyChord.Modifier.leftCommand.family == .command)
        #expect(HotkeyChord.Modifier.rightCommand.family == .command)
        #expect(HotkeyChord.Modifier.leftControl.family == .control)
        #expect(HotkeyChord.Modifier.rightControl.family == .control)
        #expect(HotkeyChord.Modifier.leftShift.family == .shift)
        #expect(HotkeyChord.Modifier.rightShift.family == .shift)
    }

    @Test func combo_display_name_prefixes_modifiers() {
        #expect(KeyCombo(keyCode: 19, modifiers: .option).displayName == "⌥2")
        #expect(KeyCombo(keyCode: 0, modifiers: [.command, .control]).displayName == "⌃⌘A")
    }

    @Test func combo_json_round_trips_with_bare_integer_modifiers() throws {
        let combo = KeyCombo(keyCode: 19, modifiers: .option)
        let data = try JSONEncoder().encode(combo)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"modifiers\":2"))
        #expect(try JSONDecoder().decode(KeyCombo.self, from: data) == combo)
    }

    @Test func unknown_key_code_names_fall_back_to_number() {
        #expect(KeyCodeNames.name(for: 200) == "Key 200")
        #expect(KeyCodeNames.name(for: 49) == "Space")
    }

    @Test func escape_key_code_is_53() {
        #expect(KeyCombo.escapeKeyCode == 53)
        #expect(KeyCodeNames.name(for: KeyCombo.escapeKeyCode) == "⎋")
    }
}
