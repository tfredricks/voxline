import Testing
import CoreGraphics
@testable import voxline

@MainActor
@Suite struct HotkeyMonitorTests {

    private let chord = HotkeyChord(modifierA: .leftShift, modifierB: .leftControl)

    @Test func command_held_true_when_command_modifier_bit_set() {
        let flags = CGEventFlags(rawValue: HotkeyChord.Modifier.leftOption.deviceMaskBit)
        #expect(HotkeyMonitor.commandIsHeld(in: flags, chord: chord, commandModifier: .leftOption) == true)
    }

    @Test func command_held_false_when_bit_absent() {
        let flags = CGEventFlags(rawValue: 0)
        #expect(HotkeyMonitor.commandIsHeld(in: flags, chord: chord, commandModifier: .leftOption) == false)
    }

    @Test func command_held_false_when_modifier_is_off() {
        let flags = CGEventFlags(rawValue: HotkeyChord.Modifier.leftOption.deviceMaskBit)
        #expect(HotkeyMonitor.commandIsHeld(in: flags, chord: chord, commandModifier: nil) == false)
    }

    @Test func command_held_false_when_modifier_collides_with_chord_key() {
        // Even with the bit set, a command modifier equal to a chord key is
        // ignored (rejected upstream) so dictation stays possible.
        let flags = CGEventFlags(rawValue: HotkeyChord.Modifier.leftShift.deviceMaskBit)
        #expect(HotkeyMonitor.commandIsHeld(in: flags, chord: chord, commandModifier: .leftShift) == false)
    }
}
