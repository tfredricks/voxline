import Foundation
import Observation

enum AppStatus: Equatable {
    case idle
    case recording
    case thinking
    /// First-run model fetch in progress. `progress` is in [0, 1].
    case downloadingModel(progress: Double)
    /// Model files are on disk but Core ML / Apple Neural Engine is still
    /// compiling them. The first run after download can take 30s-2min.
    case preparingModel
    case error(String)

    /// Recording is blocked until the model is fully ready.
    var blocksRecording: Bool {
        switch self {
        case .downloadingModel, .preparingModel: return true
        default: return false
        }
    }
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
