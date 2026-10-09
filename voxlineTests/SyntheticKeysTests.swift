// voxlineTests/SyntheticKeysTests.swift
import Carbon.HIToolbox
import CoreGraphics
import Testing
@testable import voxline

@Suite struct SyntheticKeysTests {

    @Test func tag_spells_voxl() {
        #expect(SyntheticKeys.tag == 0x766F786C)
    }

    @Test func untagged_event_is_not_tagged() throws {
        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
        #expect(!SyntheticKeys.isTagged(event))
    }

    @Test func event_carrying_tag_is_tagged() throws {
        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
        event.setIntegerValueField(.eventSourceUserData, value: SyntheticKeys.tag)
        #expect(SyntheticKeys.isTagged(event))
    }

    @Test func other_user_data_is_not_tagged() throws {
        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
        event.setIntegerValueField(.eventSourceUserData, value: 1)
        #expect(!SyntheticKeys.isTagged(event))
    }

    @Test func source_events_are_tagged_too() {
        let source = CGEventSource(stateID: .privateState)
        let keys = SyntheticKeys.keyEvents(124, flags: [], source: source)
        let chunk = SyntheticKeys.chunkEvents([0x61], source: source)
        #expect(keys.count == 2)
        #expect(chunk.count == 2)
        #expect(keys.allSatisfy(SyntheticKeys.isTagged))
        #expect(chunk.allSatisfy(SyntheticKeys.isTagged))
    }

    @Test func key_events_are_tagged_with_exact_flags() {
        let events = SyntheticKeys.keyEvents(9, flags: .maskCommand, source: nil)
        #expect(events.count == 2)
        #expect(events.map { $0.type } == [.keyDown, .keyUp])
        for event in events {
            #expect(SyntheticKeys.isTagged(event))
            #expect(event.flags == .maskCommand)
            #expect(event.getIntegerValueField(.keyboardEventKeycode) == 9)
        }
    }

    @Test func chunk_events_carry_units_on_key_down_and_are_tagged() throws {
        let units = Array("hé👍".utf16)
        let events = SyntheticKeys.chunkEvents(units, source: nil)
        #expect(events.count == 2)
        #expect(events.map { $0.type } == [.keyDown, .keyUp])
        #expect(events.allSatisfy(SyntheticKeys.isTagged))
        let down = try #require(events.first)
        var buffer = [UniChar](repeating: 0, count: 8)
        var length = 0
        down.keyboardGetUnicodeString(maxStringLength: buffer.count, actualStringLength: &length, unicodeString: &buffer)
        #expect(Array(buffer.prefix(length)) == units)
    }

    @Test func empty_chunk_builds_no_events() {
        #expect(SyntheticKeys.chunkEvents([], source: nil).isEmpty)
    }

    @Test func force_clear_event_is_tagged_flags_changed_with_empty_flags() throws {
        let event = try #require(SyntheticKeys.forceClearEvent(source: nil))
        #expect(event.type == .flagsChanged)
        #expect(event.flags == [])
        #expect(SyntheticKeys.isTagged(event))
    }

    @MainActor
    @Test func shortcut_key_for_v_on_the_current_layout_does_not_crash() {
        _ = SyntheticKeys.shortcutKeyCode(typing: "v")
    }

    // MARK: - Shortcut keys per layout

    @Test func command_modifier_key_state_is_the_command_mask_shifted_down_a_byte() {
        #expect(SyntheticKeys.commandModifierKeyState == 1)
        #expect(SyntheticKeys.commandModifierKeyState == UInt32((cmdKey >> 8) & 0xFF))
    }

    /// A layout that ships with macOS, by its input source ID.
    @MainActor
    private func layout(_ id: String) throws -> TISInputSource {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        let sources = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource]
        return try #require(sources?.first, "\(id) ships with macOS")
    }

    @MainActor
    @Test func shortcut_keys_on_us_are_c_and_v() throws {
        let us = try layout("com.apple.keylayout.US")
        #expect(SyntheticKeys.shortcutKeyCode(typing: "c", layout: us) == 8)
        #expect(SyntheticKeys.shortcutKeyCode(typing: "v", layout: us) == 9)
    }

    /// "Dvorak – QWERTY ⌘" types Dvorak but switches to QWERTY under ⌘, so
    /// ⌘C and ⌘V are the QWERTY C and V keys, not Dvorak's C (QWERTY I)
    /// and V (QWERTY period).
    @MainActor
    @Test func shortcut_keys_follow_a_layout_that_switches_to_qwerty_under_command() throws {
        let dvorakQwertyCommand = try layout("com.apple.keylayout.DVORAK-QWERTYCMD")
        #expect(SyntheticKeys.keyCode(typing: "c", layout: dvorakQwertyCommand) == 34)
        #expect(SyntheticKeys.keyCode(typing: "v", layout: dvorakQwertyCommand) == 47)
        #expect(SyntheticKeys.shortcutKeyCode(typing: "c", layout: dvorakQwertyCommand) == 8)
        #expect(SyntheticKeys.shortcutKeyCode(typing: "v", layout: dvorakQwertyCommand) == 9)
    }

    @MainActor
    @Test func shortcut_keys_on_plain_dvorak_are_its_own_c_and_v() throws {
        let dvorak = try layout("com.apple.keylayout.Dvorak")
        #expect(SyntheticKeys.shortcutKeyCode(typing: "c", layout: dvorak) == 34)
        #expect(SyntheticKeys.shortcutKeyCode(typing: "v", layout: dvorak) == 47)
    }
}
