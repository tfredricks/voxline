import Foundation
import Observation

enum AppStatus: Equatable {
    case idle
    case recording
    case thinking
    case error(String)
}

@Observable
final class AppState {
    var status: AppStatus = .idle

    /// Live mic input level while recording, in [0, 1]. Used by the
    /// recording-pill waveform. Updated from the audio thread.
    var audioLevel: Float = 0

    /// Most recently produced transcript. Plan 2 displays this in the
    /// debug window; Plan 3 will paste it instead.
    var lastTranscript: String?

    /// Wall-clock time the current recording began, or nil while idle.
    /// Used for the pill's elapsed-time display and for the max-duration fail-safe.
    var recordingStartedAt: Date?
}
