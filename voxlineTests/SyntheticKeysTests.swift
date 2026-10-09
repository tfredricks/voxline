// voxlineTests/SyntheticKeysTests.swift
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
        #expect(SyntheticKeys.keyEvents(124, flags: [], source: source).allSatisfy(SyntheticKeys.isTagged))
        #expect(SyntheticKeys.chunkEvents([0x61], source: source).allSatisfy(SyntheticKeys.isTagged))
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
    @Test func key_code_typing_v_is_nine_on_us_layout_or_unresolved() {
        let code = SyntheticKeys.keyCode(typing: "v")
        #expect(code == nil || code == 9)
    }
}
