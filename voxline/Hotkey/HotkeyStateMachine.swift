import Foundation

/// Pure state machine for the hold-to-talk chord.
/// All inputs are events; all outputs are effect descriptions.
/// No CGEventTap, no timers, no AVFoundation — fully unit-testable.
final class HotkeyStateMachine {

    enum State: Equatable, CustomStringConvertible {
        case idle
        case armed       // exactly one chord modifier down
        case recording   // both chord modifiers down, audio capture in progress
        case finalizing  // either modifier released or fail-safe fired; awaiting transcription

        var description: String {
            switch self {
            case .idle:       return "idle"
            case .armed:      return "armed"
            case .recording:  return "recording"
            case .finalizing: return "finalizing"
            }
        }
    }

    enum Input: Equatable {
        case flagsChanged(leftCtrlDown: Bool, leftOptDown: Bool)
        case maxDurationElapsed
        case tapDisabled
        case appDeactivated
        case recordingFinished
    }

    enum Output: Equatable {
        case startRecording
        case finalizeRecording
    }

    private(set) var state: State = .idle

    /// Process an input. Returns zero or more effect outputs the caller should perform.
    @discardableResult
    func handle(_ input: Input) -> [Output] {
        switch (state, input) {

        // From idle / armed, modifier flag changes drive entry into recording.
        case (.idle, .flagsChanged(let ctrl, let opt)),
             (.armed, .flagsChanged(let ctrl, let opt)):
            return reactToFlags(ctrl: ctrl, opt: opt)

        // While recording, ANY input that signals "stop" finalizes.
        case (.recording, .flagsChanged(let ctrl, let opt)) where !(ctrl && opt):
            state = .finalizing
            return [.finalizeRecording]

        case (.recording, .maxDurationElapsed),
             (.recording, .tapDisabled),
             (.recording, .appDeactivated):
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

    private func reactToFlags(ctrl: Bool, opt: Bool) -> [Output] {
        switch (ctrl, opt) {
        case (true, true):
            state = .recording
            return [.startRecording]
        case (true, false), (false, true):
            state = .armed
            return []
        case (false, false):
            state = .idle
            return []
        }
    }
}
