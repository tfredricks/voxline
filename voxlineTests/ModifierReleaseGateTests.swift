// voxlineTests/ModifierReleaseGateTests.swift
import CoreGraphics
import Testing
@testable import voxline

@Suite struct ModifierReleaseGateTests {

    private func makeGate(
        flags: LockedBox<[CGEventFlags]>,
        sleeps: LockedBox<[Duration]>,
        clears: LockedBox<Int>
    ) -> ModifierReleaseGate {
        var gate = ModifierReleaseGate()
        gate.flagsState = {
            var next: CGEventFlags = []
            flags.mutate { queue in
                guard let first = queue.first else { return }
                next = first
                if queue.count > 1 { queue.removeFirst() }
            }
            return next
        }
        gate.forceClear = { clears.mutate { $0 += 1 } }
        gate.sleep = { duration in sleeps.mutate { $0.append(duration) } }
        return gate
    }

    @Test func returns_after_release_without_force_clear() async throws {
        let flags = LockedBox<[CGEventFlags]>([.maskShift, .maskShift, []])
        let sleeps = LockedBox<[Duration]>([])
        let clears = LockedBox<Int>(0)
        let gate = makeGate(flags: flags, sleeps: sleeps, clears: clears)

        try await gate.wait(for: [.shift])

        #expect(sleeps.read() == [.milliseconds(15), .milliseconds(15)])
        #expect(clears.read() == 0)
    }

    @Test func force_clears_once_after_timeout() async throws {
        let flags = LockedBox<[CGEventFlags]>([.maskCommand])
        let sleeps = LockedBox<[Duration]>([])
        let clears = LockedBox<Int>(0)
        var gate = makeGate(flags: flags, sleeps: sleeps, clears: clears)
        gate.timeout = .milliseconds(30)
        gate.pollInterval = .milliseconds(10)

        try await gate.wait(for: [.command])

        #expect(clears.read() == 1)
        #expect(sleeps.read() == [.milliseconds(10), .milliseconds(10), .milliseconds(10)])
    }

    @Test func empty_families_return_immediately() async throws {
        let flags = LockedBox<[CGEventFlags]>([[.maskCommand, .maskShift, .maskAlternate, .maskControl]])
        let sleeps = LockedBox<[Duration]>([])
        let clears = LockedBox<Int>(0)
        let gate = makeGate(flags: flags, sleeps: sleeps, clears: clears)

        try await gate.wait(for: [])

        #expect(sleeps.read().isEmpty)
        #expect(clears.read() == 0)
    }

    @Test func unrelated_family_does_not_block() async throws {
        let flags = LockedBox<[CGEventFlags]>([.maskShift])
        let sleeps = LockedBox<[Duration]>([])
        let clears = LockedBox<Int>(0)
        let gate = makeGate(flags: flags, sleeps: sleeps, clears: clears)

        try await gate.wait(for: [.command, .option])

        #expect(sleeps.read().isEmpty)
        #expect(clears.read() == 0)
    }

    @Test func sleep_error_propagates_without_force_clear() async {
        struct Cancelled: Error {}
        let clears = LockedBox<Int>(0)
        var gate = ModifierReleaseGate()
        gate.flagsState = { .maskAlternate }
        gate.forceClear = { clears.mutate { $0 += 1 } }
        gate.sleep = { _ in throw Cancelled() }

        await #expect(throws: Cancelled.self) {
            try await gate.wait(for: [.option])
        }
        #expect(clears.read() == 0)
    }

    @Test func is_held_reads_generic_bits() {
        #expect(ModifierReleaseGate.isHeld([.shift], in: [.maskShift, .maskAlphaShift]))
        #expect(!ModifierReleaseGate.isHeld([.command], in: [.maskShift]))
        #expect(!ModifierReleaseGate.isHeld([.shift], in: [.maskAlphaShift, .maskSecondaryFn]))
        #expect(ModifierReleaseGate.isHeld([.command, .option], in: [.maskAlternate]))
        #expect(!ModifierReleaseGate.isHeld([], in: [.maskCommand]))
    }

    // MARK: - Chord predicate for the paste gate

    private let shiftControl = HotkeyChord(modifierA: .leftShift, modifierB: .leftControl)
    private let shiftOption = HotkeyChord(modifierA: .leftShift, modifierB: .leftOption)

    @Test func a_key_only_the_command_chord_uses_counts_as_held() {
        let held = ModifierReleaseGate.chordsHeld(
            { ChordSet(dictation: shiftControl, command: shiftOption) },
            flags: { .maskAlternate }
        )
        #expect(held())
    }

    @Test func a_dictation_key_counts_as_held() {
        let held = ModifierReleaseGate.chordsHeld(
            { ChordSet(dictation: shiftControl, command: shiftOption) },
            flags: { .maskControl }
        )
        #expect(held())
    }

    @Test func nothing_held_or_an_unrelated_family_is_released() {
        let chords: @Sendable () -> ChordSet = { ChordSet(dictation: self.shiftControl, command: self.shiftOption) }
        #expect(!ModifierReleaseGate.chordsHeld(chords, flags: { [] })())
        #expect(!ModifierReleaseGate.chordsHeld(chords, flags: { .maskCommand })())
    }

    @Test func with_command_mode_off_its_keys_no_longer_count() {
        let held = ModifierReleaseGate.chordsHeld(
            { ChordSet(dictation: shiftControl, command: nil) },
            flags: { .maskAlternate }
        )
        #expect(!held())
    }

    @Test func chords_and_flags_are_read_on_every_call() {
        let chords = LockedBox(ChordSet(dictation: shiftControl, command: nil))
        let held = ModifierReleaseGate.chordsHeld({ chords.read() }, flags: { .maskAlternate })
        #expect(!held())
        chords.mutate { $0.command = self.shiftOption }
        #expect(held())
    }
}
