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
    /// Sticky failure that requires the user to act in System Settings.
    /// Cleared by AppCoordinator's reconcile loop when permissions return.
    case permissionsError(String)
    /// Transient failure (audio, transcription, LLM, paste, model prep).
    /// Cleared by the next user action — chord press or successful model prep.
    case error(String)

    var blocksRecording: Bool {
        switch self {
        case .downloadingModel, .preparingModel: return true
        default: return false
        }
    }
}

extension AppStatus {
    /// Non-nil iff status is `.error` or `.permissionsError`. Used by the
    /// menu bar's error banner.
    var errorMessage: String? {
        switch self {
        case .error(let m), .permissionsError(let m): return m
        default: return nil
        }
    }
}

/// Which post-recording step is running while status is `.thinking`.
enum PipelinePhase: Equatable {
    case transcribing
    case cleaning
    case inserting
}

@Observable
@MainActor
final class AppState {
    var status: AppStatus = .idle
    var hotkeyEnabled: Bool = true

    /// Transient feedback string ("Copied" after a history-row click), or nil.
    /// `RecordingPillWindow` shows the pill while this is set. The setter that
    /// flips this on is also responsible for clearing it after a short delay.
    var toastMessage: String?

    /// Live mic input level while recording, in [0, 1]. Used by the
    /// recording-pill waveform. Updated from the audio thread.
    var audioLevel: Float = 0

    /// Most recently produced raw (pre-cleanup) transcript. Set by
    /// CapturePipeline after a successful transcription; scrubbed to
    /// nil at the start of each new recording so spoken passwords/2FA codes
    /// don't linger in process memory.
    var lastTranscript: String?

    /// Most recently produced LLM-cleaned text — i.e. exactly what was (or
    /// would have been) pasted into the focused field. Populated by
    /// CapturePipeline after the LLM step completes and before the paste step runs.
    var lastCleanedText: String?

    /// Wall-clock time the current recording began, or nil while idle.
    /// Used for the pill's elapsed-time display and for the max-duration fail-safe.
    var recordingStartedAt: Date?

    /// True while the current recording is a command gesture (command modifier
    /// held at start). Read by the recording pill to show a "Command" cue.
    /// Set at `startRecording`; only meaningful while `status == .recording`.
    var recordingIsCommand: Bool = false

    /// Duration of the most recent recording in seconds, derived from the
    /// sample count captured at 16 kHz. Nil until the first recording
    /// finalizes.
    var lastRecordingDuration: TimeInterval?

    /// Seconds the transcription session's `finish()` took on the most recent
    /// dictation. Nil until the first transcription completes.
    var lastTranscribeDuration: TimeInterval?

    /// Wall-clock seconds spent in the LLM cleanup call on the most recent
    /// dictation. Nil until the first cleanup completes (or skipped when the
    /// transcript was empty).
    var lastCleanupDuration: TimeInterval?

    /// The engine's evolving transcript while recording, then the final
    /// transcript while thinking; nil once idle.
    var liveTranscript: TranscriptPartial?

    /// Step in progress while `.thinking`; nil otherwise.
    var pipelinePhase: PipelinePhase?

    /// Raw transcript of the last dictation, kept after it finishes (or fails)
    /// so it can be cleaned and inserted again. Cleared when a new recording
    /// starts.
    var retryTranscript: String?

    /// True while Esc may cancel: recording, and thinking until insert begins.
    var isCancellable: Bool = false
}
