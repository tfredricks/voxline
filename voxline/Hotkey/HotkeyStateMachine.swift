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

    /// Latest absolute modifier flags seen, INCLUDING events that arrive while
    /// `.finalizing` (which the switch below otherwise ignores). When the
    /// pipeline reports `recordingFinished`, these flags are re-evaluated so a
    /// chord held or re-pressed during processing starts the next recording
    /// instead of being silently dropped.
    private var lastFlags: (modA: Bool, modB: Bool) = (false, false)

    /// Process an input. Returns zero or more effect outputs the caller should perform.
    @discardableResult
    func handle(_ input: Input) -> [Output] {
        if case .flagsChanged(let modA, let modB) = input {
            lastFlags = (modA, modB)
        }
        switch (state, input) {

        // From idle / armed, modifier flag changes drive entry into recording.
        case (.idle, .flagsChanged(let modA, let modB)),
             (.armed, .flagsChanged(let modA, let modB)):
            return reactToFlags(modA: modA, modB: modB)

        // While recording, ANY input that signals "stop" finalizes.
        case (.recording, .flagsChanged(let modA, let modB)) where !(modA && modB):
            state = .finalizing
            return [.finalizeRecording]

        // These inputs fire precisely when a chord-release flagsChanged event
        // may have been LOST (tap disabled) or the hold is implausibly long
        // (fail-safe). Either way lastFlags can't be trusted, so the
        // resume-on-recordingFinished path below must not fire from stale
        // data — reset it and make the user re-press. A fresh flagsChanged
        // arriving during finalizing (the user re-pressing) updates lastFlags
        // again and resume works as normal; that case is unaffected.
        case (.recording, .maxDurationElapsed),
             (.recording, .tapDisabled):
            lastFlags = (false, false)
            state = .finalizing
            return [.finalizeRecording]

        // Recording finished: re-evaluate the flags the user is holding RIGHT NOW.
        // Both held -> start the next dictation immediately (the start sound tells
        // the user the mic is live). One held -> re-arm (and prewarm). None -> idle.
        case (.finalizing, .recordingFinished):
            return reactToFlags(modA: lastFlags.modA, modB: lastFlags.modB)

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
