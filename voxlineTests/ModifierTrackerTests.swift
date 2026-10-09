// voxlineTests/ModifierTrackerTests.swift
import CoreGraphics
import Foundation
import Testing
@testable import voxline

@Suite struct ModifierTrackerTests {

    private typealias M = HotkeyChord.Modifier

    private func flags(_ generic: CGEventFlags, device: [M] = []) -> CGEventFlags {
        CGEventFlags(rawValue: device.reduce(generic.rawValue) { $0 | $1.deviceMaskBit })
    }

    @Test func device_bits_name_sides() {
        var tracker = ModifierTracker()
        #expect(tracker.update(flags: flags(.maskShift, device: [.leftShift]), keyCode: 56) == [.leftShift])
        #expect(tracker.update(flags: flags(.maskShift, device: [.leftShift, .rightShift]), keyCode: 60) == [.leftShift, .rightShift])
    }

    @Test func generic_only_toggles_the_keycodes_side() {
        var tracker = ModifierTracker()
        #expect(tracker.update(flags: .maskShift, keyCode: 56) == [.leftShift])
        #expect(tracker.update(flags: .maskShift, keyCode: 60) == [.leftShift, .rightShift])
        #expect(tracker.update(flags: .maskShift, keyCode: 60) == [.leftShift])
        #expect(tracker.update(flags: [], keyCode: 60) == [])
    }

    @Test func generic_only_foreign_keycode_keeps_last_sides() {
        var tracker = ModifierTracker()
        #expect(tracker.update(flags: flags(.maskShift, device: [.rightShift]), keyCode: 60) == [.rightShift])
        #expect(tracker.update(flags: [.maskShift, .maskControl], keyCode: 59) == [.rightShift, .leftControl])
    }

    @Test func generic_only_foreign_keycode_defaults_left() {
        var tracker = ModifierTracker()
        #expect(tracker.update(flags: [.maskCommand, .maskShift], keyCode: 56) == [.leftCommand, .leftShift])
    }

    @Test func clearing_the_generic_bit_releases_the_family() {
        var tracker = ModifierTracker()
        tracker.update(flags: flags([.maskShift, .maskControl], device: [.leftShift, .leftControl]), keyCode: 59)
        #expect(tracker.held == [.leftShift, .leftControl])
        #expect(tracker.update(flags: .maskControl, keyCode: 56) == [.leftControl])
    }

    @Test func both_sides_then_one_released_by_device_bits() {
        var tracker = ModifierTracker()
        #expect(tracker.update(flags: flags(.maskShift, device: [.leftShift, .rightShift]), keyCode: 60) == [.leftShift, .rightShift])
        #expect(tracker.update(flags: flags(.maskShift, device: [.rightShift]), keyCode: 56) == [.rightShift])
    }

    @Test func toggling_the_only_held_side_off_while_the_generic_bit_stays_keeps_left() {
        var tracker = ModifierTracker()
        tracker.update(flags: .maskShift, keyCode: 56)
        #expect(tracker.update(flags: .maskShift, keyCode: 56) == [.leftShift])
    }

    @Test func generic_only_right_keycode_on_a_fresh_family_holds_only_the_right_side() {
        var tracker = ModifierTracker()
        #expect(tracker.update(flags: .maskCommand, keyCode: 54) == [.rightCommand])
    }

    @Test func each_family_maps_its_keycodes() {
        let cases: [(CGEventFlags, Int64, Int64, M, M)] = [
            (.maskShift, 56, 60, .leftShift, .rightShift),
            (.maskControl, 59, 62, .leftControl, .rightControl),
            (.maskAlternate, 58, 61, .leftOption, .rightOption),
            (.maskCommand, 55, 54, .leftCommand, .rightCommand),
        ]
        for (generic, leftCode, rightCode, left, right) in cases {
            var tracker = ModifierTracker()
            #expect(tracker.update(flags: generic, keyCode: leftCode) == [left])
            #expect(tracker.update(flags: generic, keyCode: rightCode) == [left, right])
        }
    }

    @Test func caps_lock_fn_and_keypad_are_ignored() {
        var tracker = ModifierTracker()
        #expect(tracker.update(flags: [.maskAlphaShift, .maskSecondaryFn, .maskNumericPad], keyCode: 57) == [])
    }

    @Test func reset_replaces_the_held_set() {
        var tracker = ModifierTracker()
        tracker.update(flags: .maskShift, keyCode: 56)
        tracker.reset(to: [.rightOption])
        #expect(tracker.held == [.rightOption])
    }

    @Test func a_reset_side_survives_a_generic_only_foreign_keycode_event() {
        var tracker = ModifierTracker()
        tracker.reset(to: [.rightShift])
        #expect(tracker.update(flags: [.maskShift, .maskControl], keyCode: 59) == [.rightShift, .leftControl])
    }
}
