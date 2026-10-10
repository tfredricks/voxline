import Testing
import Foundation
@testable import voxline

@Suite struct HotkeyStateMachineTests {

    typealias Modifier = HotkeyChord.Modifier

    private let d = HotkeyChord.default.keys
    private let c = HotkeyChord.defaultCommand.keys
    private let shift: Set<Modifier> = [.leftShift]

    private func machine(_ chords: ChordSet = .default) -> HotkeyStateMachine {
        HotkeyStateMachine(chords: chords)
    }

    private func recording(_ kind: CaptureKind = .dictation) -> HotkeyStateMachine {
        let m = machine()
        m.handle(.modifiersChanged(kind == .dictation ? d : c))
        return m
    }

    private func blocked() -> HotkeyStateMachine {
        let m = machine()
        m.handle(.modifiersChanged(d.union([.leftCommand])))
        return m
    }

    private func finalizing(_ kind: CaptureKind = .dictation) -> HotkeyStateMachine {
        let m = recording(kind)
        m.handle(.modifiersChanged([]))
        return m
    }

    // MARK: - Idle and armed

    @Test func starts_idle_with_default_chords() {
        let m = HotkeyStateMachine()
        #expect(m.state == .idle)
        #expect(m.chords == .default)
    }

    @Test func shared_key_arms_then_dictation_chord_records() {
        let m = machine()
        #expect(m.handle(.modifiersChanged(shift)) == [.beginPrewarm])
        #expect(m.state == .armed)
        #expect(m.handle(.modifiersChanged(d)) == [.startRecording(.dictation)])
        #expect(m.state == .recording(.dictation))
    }

    @Test func shared_key_arms_then_command_chord_records() {
        let m = machine()
        m.handle(.modifiersChanged(shift))
        #expect(m.handle(.modifiersChanged(c)) == [.startRecording(.command)])
        #expect(m.state == .recording(.command))
    }

    @Test func non_shared_key_arms() {
        let m = machine()
        #expect(m.handle(.modifiersChanged([.leftOption])) == [.beginPrewarm])
        #expect(m.state == .armed)
    }

    @Test func chord_from_idle_records_without_arming() {
        let m = machine()
        #expect(m.handle(.modifiersChanged(d)) == [.startRecording(.dictation)])
        #expect(m.state == .recording(.dictation))
    }

    @Test func release_from_armed_goes_idle_and_cancels_prewarm() {
        let m = machine()
        m.handle(.modifiersChanged(shift))
        #expect(m.handle(.modifiersChanged([])) == [.cancelPrewarm])
        #expect(m.state == .idle)
    }

    @Test func armed_reasserted_emits_nothing() {
        let m = machine()
        m.handle(.modifiersChanged(shift))
        #expect(m.handle(.modifiersChanged(shift)).isEmpty)
        #expect(m.state == .armed)
    }

    @Test func armed_switching_to_another_strict_subset_stays_armed_quietly() {
        let m = machine()
        m.handle(.modifiersChanged([.leftControl]))
        #expect(m.handle(.modifiersChanged([.leftOption])).isEmpty)
        #expect(m.state == .armed)
    }

    @Test func empty_from_idle_emits_nothing() {
        let m = machine()
        #expect(m.handle(.modifiersChanged([])).isEmpty)
        #expect(m.state == .idle)
    }

    @Test func key_down_in_idle_is_ignored() {
        let m = machine()
        #expect(m.handle(.keyDown).isEmpty)
        #expect(m.state == .idle)
    }

    @Test func key_down_while_armed_blocks_and_cancels_prewarm() {
        let m = machine()
        m.handle(.modifiersChanged(shift))
        #expect(m.handle(.keyDown) == [.cancelPrewarm])
        #expect(m.state == .blocked)
    }

    @Test func key_down_while_armed_then_completing_the_chord_never_records() {
        let m = machine()
        m.handle(.modifiersChanged(shift))
        m.handle(.keyDown)
        #expect(m.handle(.modifiersChanged(d)).isEmpty)
        #expect(m.state == .blocked)
    }

    // MARK: - Supersets and blocked

    @Test func superset_from_idle_blocks_silently() {
        let m = machine()
        #expect(m.handle(.modifiersChanged(d.union([.leftCommand]))).isEmpty)
        #expect(m.state == .blocked)
    }

    @Test func superset_from_armed_blocks_and_cancels_prewarm() {
        let m = machine()
        m.handle(.modifiersChanged(shift))
        #expect(m.handle(.modifiersChanged(d.union([.leftCommand]))) == [.cancelPrewarm])
        #expect(m.state == .blocked)
    }

    @Test func non_chord_modifier_from_idle_blocks() {
        let m = machine()
        #expect(m.handle(.modifiersChanged([.leftCommand])).isEmpty)
        #expect(m.state == .blocked)
    }

    @Test func right_side_of_a_chord_key_is_not_a_subset() {
        let m = machine()
        #expect(m.handle(.modifiersChanged([.rightShift])).isEmpty)
        #expect(m.state == .blocked)
    }

    @Test func blocked_stays_blocked_while_any_key_is_held() {
        let m = blocked()
        #expect(m.handle(.modifiersChanged(d)).isEmpty)
        #expect(m.state == .blocked)
        #expect(m.handle(.modifiersChanged(shift)).isEmpty)
        #expect(m.state == .blocked)
        #expect(m.handle(.modifiersChanged([])).isEmpty)
        #expect(m.state == .idle)
    }

    @Test func superset_shrinking_to_the_exact_chord_never_records() {
        let m = machine()
        var outputs: [HotkeyStateMachine.Output] = []
        outputs += m.handle(.modifiersChanged([.leftCommand]))
        outputs += m.handle(.modifiersChanged(d.union([.leftCommand])))
        outputs += m.handle(.modifiersChanged(d))
        #expect(outputs.isEmpty)
        #expect(m.state == .blocked)
    }

    @Test func blocked_ignores_key_down_and_timers() {
        let m = blocked()
        #expect(m.handle(.keyDown).isEmpty)
        #expect(m.handle(.shortcutWindowClosed).isEmpty)
        #expect(m.handle(.maxDurationElapsed).isEmpty)
        #expect(m.handle(.recordingFinished).isEmpty)
        #expect(m.state == .blocked)
    }

    @Test func after_blocked_clears_the_chord_records_again() {
        let m = blocked()
        m.handle(.modifiersChanged([]))
        #expect(m.handle(.modifiersChanged(d)) == [.startRecording(.dictation)])
    }

    // MARK: - Recording: shortcut window

    @Test func key_down_inside_the_window_discards() {
        let m = recording()
        #expect(m.handle(.keyDown) == [.discardRecording(.dictation)])
        #expect(m.state == .blocked)
    }

    @Test func extra_modifier_inside_the_window_discards() {
        let m = recording()
        #expect(m.handle(.modifiersChanged(d.union([.leftCommand]))) == [.discardRecording(.dictation)])
        #expect(m.state == .blocked)
    }

    @Test func discarded_command_names_its_kind() {
        let m = recording(.command)
        #expect(m.handle(.keyDown) == [.discardRecording(.command)])
        #expect(m.state == .blocked)
    }

    @Test func discard_then_full_release_returns_idle() {
        let m = recording()
        m.handle(.keyDown)
        #expect(m.handle(.modifiersChanged(d)).isEmpty)
        #expect(m.state == .blocked)
        #expect(m.handle(.modifiersChanged([])).isEmpty)
        #expect(m.state == .idle)
    }

    @Test func key_down_after_the_window_is_ignored() {
        let m = recording()
        #expect(m.handle(.shortcutWindowClosed).isEmpty)
        #expect(m.handle(.keyDown).isEmpty)
        #expect(m.state == .recording(.dictation))
    }

    @Test func extra_modifier_after_the_window_is_ignored() {
        let m = recording()
        m.handle(.shortcutWindowClosed)
        #expect(m.handle(.modifiersChanged(d.union([.leftCommand]))).isEmpty)
        #expect(m.state == .recording(.dictation))
        #expect(m.handle(.modifiersChanged(d)).isEmpty)
        #expect(m.state == .recording(.dictation))
    }

    @Test func chord_reasserted_while_recording_emits_nothing() {
        let m = recording()
        #expect(m.handle(.modifiersChanged(d)).isEmpty)
        #expect(m.state == .recording(.dictation))
    }

    // MARK: - Recording: release, cap, input lost

    @Test func releasing_one_key_finalizes() {
        let m = recording()
        #expect(m.handle(.modifiersChanged([.leftControl])) == [.finalizeRecording(.dictation)])
        #expect(m.state == .finalizing(.dictation))
    }

    @Test func releasing_one_command_key_finalizes_command() {
        let m = recording(.command)
        #expect(m.handle(.modifiersChanged(shift)) == [.finalizeRecording(.command)])
        #expect(m.state == .finalizing(.command))
    }

    @Test func release_is_checked_before_superset_inside_the_window() {
        let m = recording()
        let swapped = d.subtracting([.leftControl]).union([.leftCommand])
        #expect(m.handle(.modifiersChanged(swapped)) == [.finalizeRecording(.dictation)])
        #expect(m.state == .finalizing(.dictation))
    }

    @Test func max_duration_finalizes_and_does_not_restart_from_stale_keys() {
        let m = recording()
        #expect(m.handle(.maxDurationElapsed) == [.finalizeRecording(.dictation)])
        #expect(m.state == .finalizing(.dictation))
        #expect(m.handle(.recordingFinished).isEmpty)
        #expect(m.state == .idle)
    }

    @Test func input_lost_finalizes_and_does_not_restart_from_stale_keys() {
        let m = recording(.command)
        #expect(m.handle(.inputLost) == [.finalizeRecording(.command)])
        #expect(m.state == .finalizing(.command))
        #expect(m.handle(.recordingFinished).isEmpty)
        #expect(m.state == .idle)
    }

    @Test func resync_while_recording_is_ignored() {
        let m = recording()
        #expect(m.handle(.resync([])).isEmpty)
        #expect(m.state == .recording(.dictation))
    }

    @Test func recording_finished_while_recording_is_ignored() {
        let m = recording()
        #expect(m.handle(.recordingFinished).isEmpty)
        #expect(m.state == .recording(.dictation))
    }

    // MARK: - Finalizing

    @Test func finalizing_ignores_every_event_until_finished() {
        let m = finalizing()
        #expect(m.handle(.modifiersChanged(d)).isEmpty)
        #expect(m.handle(.keyDown).isEmpty)
        #expect(m.handle(.shortcutWindowClosed).isEmpty)
        #expect(m.handle(.maxDurationElapsed).isEmpty)
        #expect(m.state == .finalizing(.dictation))
    }

    @Test func chord_held_through_finalizing_records_again_with_a_fresh_window() {
        let m = finalizing()
        m.handle(.modifiersChanged(d))
        #expect(m.handle(.recordingFinished) == [.startRecording(.dictation)])
        #expect(m.state == .recording(.dictation))
        #expect(m.handle(.keyDown) == [.discardRecording(.dictation)])
    }

    @Test func command_chord_held_through_dictation_finalizing_records_command() {
        let m = finalizing(.dictation)
        m.handle(.modifiersChanged(c))
        #expect(m.handle(.recordingFinished) == [.startRecording(.command)])
    }

    @Test func released_during_finalizing_goes_idle() {
        let m = finalizing()
        m.handle(.modifiersChanged(d))
        m.handle(.modifiersChanged([]))
        #expect(m.handle(.recordingFinished).isEmpty)
        #expect(m.state == .idle)
    }

    @Test func shared_key_held_after_finalizing_arms_and_prewarms() {
        let m = recording()
        m.handle(.modifiersChanged(shift))
        #expect(m.handle(.recordingFinished) == [.beginPrewarm])
        #expect(m.state == .armed)
    }

    @Test func superset_held_after_finalizing_blocks() {
        let m = finalizing()
        m.handle(.modifiersChanged(d.union([.leftCommand])))
        #expect(m.handle(.recordingFinished).isEmpty)
        #expect(m.state == .blocked)
    }

    @Test func key_down_on_the_held_chord_during_finalizing_blocks_instead_of_recording() {
        let m = finalizing(.command)
        m.handle(.modifiersChanged(c))
        #expect(m.handle(.keyDown).isEmpty)
        #expect(m.state == .finalizing(.command))
        #expect(m.handle(.recordingFinished).isEmpty)
        #expect(m.state == .blocked)
        m.handle(.modifiersChanged([]))
        #expect(m.state == .idle)
    }

    @Test func key_down_on_a_shared_key_during_finalizing_blocks_instead_of_arming() {
        let m = finalizing(.command)
        m.handle(.modifiersChanged([.leftOption]))
        m.handle(.keyDown)
        #expect(m.handle(.recordingFinished).isEmpty)
        #expect(m.state == .blocked)
    }

    @Test func key_down_with_nothing_held_during_finalizing_does_not_block() {
        let m = finalizing()
        m.handle(.keyDown)
        m.handle(.modifiersChanged(d))
        #expect(m.handle(.recordingFinished) == [.startRecording(.dictation)])
    }

    @Test func superset_shrinking_to_the_chord_during_finalizing_blocks() {
        let m = finalizing()
        m.handle(.modifiersChanged(d.union([.leftCommand])))
        m.handle(.modifiersChanged(d))
        #expect(m.handle(.recordingFinished).isEmpty)
        #expect(m.state == .blocked)
        m.handle(.modifiersChanged([]))
        #expect(m.state == .idle)
    }

    @Test func superset_left_by_the_finalizing_release_keeps_the_chord_blocked() {
        let m = recording()
        m.handle(.shortcutWindowClosed)
        m.handle(.modifiersChanged(d.union([.leftCommand])))
        #expect(m.handle(.modifiersChanged([.leftShift, .leftCommand])) == [.finalizeRecording(.dictation)])
        m.handle(.modifiersChanged(shift))
        m.handle(.modifiersChanged(d))
        #expect(m.handle(.recordingFinished).isEmpty)
        #expect(m.state == .blocked)
    }

    @Test func full_release_after_a_key_down_during_finalizing_clears_the_block() {
        let m = finalizing(.command)
        m.handle(.modifiersChanged(c))
        m.handle(.keyDown)
        m.handle(.modifiersChanged([]))
        m.handle(.modifiersChanged(c))
        #expect(m.handle(.recordingFinished) == [.startRecording(.command)])
    }

    @Test func full_release_after_a_superset_during_finalizing_clears_the_block() {
        let m = finalizing()
        m.handle(.modifiersChanged(d.union([.leftCommand])))
        m.handle(.modifiersChanged([]))
        m.handle(.modifiersChanged(d))
        #expect(m.handle(.recordingFinished) == [.startRecording(.dictation)])
    }

    @Test func chord_held_at_a_resync_during_finalizing_blocks_instead_of_recording() {
        let m = finalizing()
        #expect(m.handle(.resync(d)).isEmpty)
        #expect(m.state == .finalizing(.dictation))
        #expect(m.handle(.recordingFinished).isEmpty)
        #expect(m.state == .blocked)
        m.handle(.modifiersChanged([]))
        #expect(m.state == .idle)
        #expect(m.handle(.modifiersChanged(d)) == [.startRecording(.dictation)])
    }

    @Test func full_release_after_a_resync_during_finalizing_clears_the_block() {
        let m = finalizing()
        m.handle(.resync(d))
        m.handle(.modifiersChanged([]))
        m.handle(.modifiersChanged(d))
        #expect(m.handle(.recordingFinished) == [.startRecording(.dictation)])
    }

    @Test func partial_release_after_a_resync_during_finalizing_still_blocks() {
        let m = finalizing()
        m.handle(.resync(d))
        m.handle(.modifiersChanged(shift))
        #expect(m.handle(.recordingFinished).isEmpty)
        #expect(m.state == .blocked)
    }

    @Test func empty_resync_during_finalizing_goes_idle() {
        let m = finalizing()
        m.handle(.resync([]))
        #expect(m.handle(.recordingFinished).isEmpty)
        #expect(m.state == .idle)
    }

    @Test func input_lost_after_a_resync_during_finalizing_goes_idle() {
        let m = finalizing()
        m.handle(.resync(d))
        m.handle(.inputLost)
        #expect(m.handle(.recordingFinished).isEmpty)
        #expect(m.state == .idle)
    }

    @Test func the_block_from_a_resync_does_not_outlive_its_finalizing() {
        let m = finalizing()
        m.handle(.resync(d))
        m.handle(.recordingFinished)
        m.handle(.inputLost)
        m.handle(.modifiersChanged(d))
        m.handle(.modifiersChanged(shift))
        #expect(m.state == .finalizing(.dictation))
        m.handle(.modifiersChanged(d))
        #expect(m.handle(.recordingFinished) == [.startRecording(.dictation)])
    }

    @Test func input_lost_during_finalizing_clears_the_stored_keys() {
        let m = finalizing()
        m.handle(.modifiersChanged(d))
        #expect(m.handle(.inputLost).isEmpty)
        #expect(m.state == .finalizing(.dictation))
        #expect(m.handle(.recordingFinished).isEmpty)
        #expect(m.state == .idle)
    }

    @Test func recording_finished_outside_finalizing_is_ignored() {
        let m = machine()
        #expect(m.handle(.recordingFinished).isEmpty)
        #expect(m.state == .idle)
    }

    @Test func max_duration_outside_recording_is_ignored() {
        let m = machine()
        m.handle(.modifiersChanged(shift))
        #expect(m.handle(.maxDurationElapsed).isEmpty)
        #expect(m.state == .armed)
    }

    // MARK: - Input lost and resync

    @Test func input_lost_in_idle_stays_idle() {
        let m = machine()
        #expect(m.handle(.inputLost).isEmpty)
        #expect(m.state == .idle)
    }

    @Test func input_lost_in_armed_goes_idle_and_cancels_prewarm() {
        let m = machine()
        m.handle(.modifiersChanged(shift))
        #expect(m.handle(.inputLost) == [.cancelPrewarm])
        #expect(m.state == .idle)
    }

    @Test func input_lost_in_blocked_goes_idle() {
        let m = blocked()
        #expect(m.handle(.inputLost).isEmpty)
        #expect(m.state == .idle)
    }

    @Test func resync_with_the_chord_held_in_idle_blocks() {
        let m = machine()
        #expect(m.handle(.resync(d)).isEmpty)
        #expect(m.state == .blocked)
        #expect(m.handle(.modifiersChanged(d)).isEmpty)
        #expect(m.state == .blocked)
    }

    @Test func resync_empty_in_idle_stays_idle() {
        let m = machine()
        #expect(m.handle(.resync([])).isEmpty)
        #expect(m.state == .idle)
    }

    @Test func resync_empty_in_armed_goes_idle_and_cancels_prewarm() {
        let m = machine()
        m.handle(.modifiersChanged(shift))
        #expect(m.handle(.resync([])) == [.cancelPrewarm])
        #expect(m.state == .idle)
    }

    @Test func resync_held_in_armed_blocks_and_cancels_prewarm() {
        let m = machine()
        m.handle(.modifiersChanged(shift))
        #expect(m.handle(.resync(shift)) == [.cancelPrewarm])
        #expect(m.state == .blocked)
    }

    @Test func resync_held_in_blocked_stays_blocked() {
        let m = blocked()
        #expect(m.handle(.resync(shift)).isEmpty)
        #expect(m.state == .blocked)
    }

    @Test func resync_empty_in_blocked_goes_idle() {
        let m = blocked()
        #expect(m.handle(.resync([])).isEmpty)
        #expect(m.state == .idle)
    }

    // MARK: - Command mode off

    @Test func command_mode_off_blocks_the_command_chord() {
        let m = machine(ChordSet(dictation: .default, command: nil))
        #expect(m.handle(.modifiersChanged(c)).isEmpty)
        #expect(m.state == .blocked)
    }

    @Test func command_mode_off_still_arms_on_a_dictation_key() {
        let m = machine(ChordSet(dictation: .default, command: nil))
        #expect(m.handle(.modifiersChanged(shift)) == [.beginPrewarm])
        #expect(m.state == .armed)
        #expect(m.handle(.modifiersChanged(d)) == [.startRecording(.dictation)])
    }

    @Test func command_mode_off_blocks_the_command_only_key() {
        let m = machine(ChordSet(dictation: .default, command: nil))
        #expect(m.handle(.modifiersChanged([.leftOption])).isEmpty)
        #expect(m.state == .blocked)
    }

    @Test func reassigned_chords_apply_to_the_next_evaluation() {
        let m = machine()
        m.chords = ChordSet(dictation: HotkeyChord(modifierA: .rightCommand, modifierB: .rightOption), command: nil)
        #expect(m.handle(.modifiersChanged(d)).isEmpty)
        #expect(m.state == .blocked)
        m.handle(.modifiersChanged([]))
        #expect(m.handle(.modifiersChanged([.rightCommand, .rightOption])) == [.startRecording(.dictation)])
    }
}
