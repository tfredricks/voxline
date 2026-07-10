import Testing
import Foundation
@testable import voxline

@Suite struct HotkeyStateMachineTests {

    // MARK: - Helpers

    private func machine() -> HotkeyStateMachine {
        HotkeyStateMachine()
    }

    /// Convenience: fire flagsChanged with the named modifiers held.
    private func leftCtrl(_ down: Bool) -> HotkeyStateMachine.Input {
        .flagsChanged(modAFlag: down, modBFlag: false)
    }
    private func leftOpt(_ down: Bool) -> HotkeyStateMachine.Input {
        .flagsChanged(modAFlag: false, modBFlag: down)
    }
    private func chord(_ ctrl: Bool, _ opt: Bool) -> HotkeyStateMachine.Input {
        .flagsChanged(modAFlag: ctrl, modBFlag: opt)
    }

    // MARK: - Initial state

    @Test func startsIdle() {
        #expect(machine().state == .idle)
    }

    // MARK: - Single modifier transitions

    @Test func leftCtrlDownAlone_armsAndBeginsPrewarm() {
        let m = machine()
        let outputs = m.handle(leftCtrl(true))
        #expect(m.state == .armed)
        #expect(outputs == [.beginPrewarm], "one modifier down should warm the engine, not record")
    }

    @Test func leftCtrlReleasedFromArmed_returnsToIdleAndCancelsPrewarm() {
        let m = machine()
        _ = m.handle(leftCtrl(true))
        let outputs = m.handle(leftCtrl(false))
        #expect(m.state == .idle)
        #expect(outputs == [.cancelPrewarm])
    }

    @Test func armedReasserted_doesNotRePrewarm() {
        let m = machine()
        _ = m.handle(leftCtrl(true))
        // Same single modifier re-asserted (e.g. key-repeat flags event).
        let outputs = m.handle(leftCtrl(true))
        #expect(m.state == .armed)
        #expect(outputs.isEmpty, "armed → armed must not emit a second beginPrewarm")
    }

    @Test func chordCompletionFromArmed_emitsOnlyStartRecording() {
        let m = machine()
        _ = m.handle(leftCtrl(true))
        let outputs = m.handle(chord(true, true))
        #expect(outputs == [.startRecording], "start() owns the engine; no cancelPrewarm on chord completion")
    }

    @Test func fullReleaseFromIdle_emitsNothing() {
        let m = machine()
        let outputs = m.handle(chord(false, false))
        #expect(m.state == .idle)
        #expect(outputs.isEmpty)
    }

    // MARK: - Chord enters recording

    @Test func bothModifiersDown_startsRecording() {
        let m = machine()
        _ = m.handle(leftCtrl(true))
        let outputs = m.handle(chord(true, true))
        #expect(m.state == .recording)
        #expect(outputs == [.startRecording])
    }

    @Test func releasingEitherModifier_finalizesRecording() {
        let m = machine()
        _ = m.handle(chord(true, true))
        let outputs = m.handle(leftCtrl(true))  // ctrl still held, opt released → chord broken
        #expect(m.state == .finalizing)
        #expect(outputs == [.finalizeRecording])
    }

    @Test func releasingOtherModifier_finalizesRecording() {
        let m = machine()
        _ = m.handle(chord(true, true))
        let outputs = m.handle(leftOpt(true))  // opt still held, ctrl released → chord broken
        #expect(m.state == .finalizing)
        #expect(outputs == [.finalizeRecording])
    }

    // MARK: - Fail-safes

    @Test func maxDurationElapsed_finalizesIfRecording() {
        let m = machine()
        _ = m.handle(chord(true, true))
        let outputs = m.handle(.maxDurationElapsed)
        #expect(m.state == .finalizing)
        #expect(outputs == [.finalizeRecording])
    }

    @Test func maxDurationElapsed_isNoOpIfNotRecording() {
        let m = machine()
        let outputs = m.handle(.maxDurationElapsed)
        #expect(m.state == .idle)
        #expect(outputs.isEmpty)
    }

    @Test func tapDisabled_finalizesIfRecording() {
        let m = machine()
        _ = m.handle(chord(true, true))
        let outputs = m.handle(.tapDisabled)
        #expect(m.state == .finalizing)
        #expect(outputs == [.finalizeRecording])
    }

    // MARK: - Finalizing → idle

    @Test func recordingFinished_returnsToIdle() {
        let m = machine()
        _ = m.handle(chord(true, true))
        _ = m.handle(leftCtrl(true))  // -> finalizing
        let outputs = m.handle(.recordingFinished)
        #expect(m.state == .idle)
        #expect(outputs.isEmpty)
    }

    // MARK: - Edge cases

    @Test func chordPressedFromIdleWithoutInterimArmedState_isAccepted() {
        // If both modifiers go down in the same event (tight rollover),
        // skip the armed step and go straight to recording.
        let m = machine()
        let outputs = m.handle(chord(true, true))
        #expect(m.state == .recording)
        #expect(outputs == [.startRecording])
    }

    @Test func newFlagsChangedDuringFinalizing_isIgnored() {
        // While we're waiting for transcription to finish, additional
        // modifier events should not start a new recording.
        let m = machine()
        _ = m.handle(chord(true, true))
        _ = m.handle(leftCtrl(true))  // -> finalizing
        let outputs = m.handle(chord(true, true))
        #expect(m.state == .finalizing)
        #expect(outputs.isEmpty)
    }

    @Test func tapDisabled_isNoOpIfNotRecording() {
        let m = machine()
        let outputs = m.handle(.tapDisabled)
        #expect(m.state == .idle)
        #expect(outputs.isEmpty)
    }

    @Test func recordingFinished_isNoOpIfNotFinalizing() {
        let m = machine()
        let outputs = m.handle(.recordingFinished)
        #expect(m.state == .idle)
        #expect(outputs.isEmpty)
    }

    @Test func chordStillHeldDuringRecording_isNoOp() {
        let m = machine()
        _ = m.handle(chord(true, true))
        // Re-asserting the same chord state should not produce a second startRecording.
        let outputs = m.handle(chord(true, true))
        #expect(m.state == .recording)
        #expect(outputs.isEmpty)
    }
}
