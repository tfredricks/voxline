import Foundation

/// Pure state machine for the hold-to-talk chord.
/// All inputs are events; all outputs are effect descriptions.
/// No CGEventTap, no timers, no AVFoundation — fully unit-testable.
final class HotkeyStateMachine {

    enum State: Equatable {
        case idle
        case armed       // exactly one chord modifier down
        case recording   // both chord modifiers down, audio capture in progress
        case finalizing  // either modifier released or fail-safe fired; awaiting transcription
    }

    enum Input: Equatable {
        case flagsChanged(modAFlag: Bool, modBFlag: Bool)
        case maxDurationElapsed
        case tapDisabled
        case recordingFinished
    }

    enum Output: Equatable {
        case startRecording
        case finalizeRecording
        /// One chord modifier just went down (entered .armed). The caller
        /// should warm up the audio engine so a completed chord captures
        /// from the first syllable.
        case beginPrewarm
        /// The armed modifier was released without completing the chord;
        /// tear down the warmed engine.
        case cancelPrewarm
    }

    private(set) var state: State = .idle

    /// Process an input. Returns zero or more effect outputs the caller should perform.
    @discardableResult
    func handle(_ input: Input) -> [Output] {
        switch (state, input) {

        // From idle / armed, modifier flag changes drive entry into recording.
        case (.idle, .flagsChanged(let modA, let modB)),
             (.armed, .flagsChanged(let modA, let modB)):
            return reactToFlags(modA: modA, modB: modB)

        // While recording, ANY input that signals "stop" finalizes.
        case (.recording, .flagsChanged(let modA, let modB)) where !(modA && modB):
            state = .finalizing
            return [.finalizeRecording]

        case (.recording, .maxDurationElapsed),
             (.recording, .tapDisabled):
            state = .finalizing
            return [.finalizeRecording]

        // Recording finished signal moves us back to idle.
        case (.finalizing, .recordingFinished):
            state = .idle
            return []

        // Any other input in any other state is a no-op.
        default:
            return []
        }
    }

    private func reactToFlags(modA: Bool, modB: Bool) -> [Output] {
        let previous = state
        switch (modA, modB) {
        case (true, true):
            state = .recording
            return [.startRecording]
        case (true, false), (false, true):
            state = .armed
            return previous == .armed ? [] : [.beginPrewarm]
        case (false, false):
            state = .idle
            return previous == .armed ? [.cancelPrewarm] : []
        }
    }
}
