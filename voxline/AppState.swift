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
    case editing
    case inserting
}

/// A button a toast offers, such as Undo on "Learned: Argmax".
struct ToastAction {
    let title: String
    let perform: @MainActor () -> Void
}

@Observable
@MainActor
final class AppState {
    var status: AppStatus = .idle {
        didSet { errorOffersRetry = false }
    }
    var hotkeyEnabled: Bool = true

    /// Transient feedback string ("Copied" after a history-row click), or nil.
    /// `RecordingPillWindow` shows the pill while this is set. Set it through
    /// `flashToast(_:for:)`, which clears it again.
    var toastMessage: String?

    /// The button shown with `toastMessage`, if any. Set and cleared with it
    /// by `flashToast(_:for:action:)`.
    var toastAction: ToastAction?

    @ObservationIgnored private var toastToken: UInt64 = 0

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

    /// Which chord started the current recording, latched at `startRecording`
    /// for the work that follows it; nil once the pipeline is idle or showing
    /// an error. The recording pill shows a "Command" cue for `.command`.
    var recordingKind: CaptureKind?

    /// Shown by the pill in place of the phase label while set ("Fix
    /// grammar…" for a preset).
    var activityLabel: String?

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

    /// Whether the pill offers Retry for the error showing: set with the error
    /// of a dictation or retry that failed after transcription, while
    /// `retryTranscript` holds its transcript. Any status change clears it,
    /// so an unrelated error never offers to insert an old dictation.
    private(set) var errorOffersRetry = false

    /// Shows `message` as an error the pill offers Retry for.
    func showRetryableError(_ message: String) {
        status = .error(message)
        errorOffersRetry = retryTranscript != nil
    }

    /// Whether `CapturePipeline.retryLastDictation` would run now: a
    /// transcript is kept and the pipeline is idle or showing an error.
    var canRetryLastDictation: Bool {
        guard retryTranscript != nil else { return false }
        switch status {
        case .idle, .error: return true
        default:            return false
        }
    }

    /// True while Esc may cancel: recording, and thinking until insert begins.
    var isCancellable: Bool = false

    /// The meetings feature, once the app has started. Nil before launch
    /// finishes and in tests.
    var meetings: MeetingController?

    /// Number of Settings recorders capturing a shortcut right now. Above
    /// zero, hotkey input is suspended so recording a chord can't start a
    /// dictation (issue 10).
    private(set) var shortcutCaptureDepth: Int = 0

    /// Shows `message`, with `action` as a button when given, then clears
    /// both after `duration` unless another toast or a direct write replaced
    /// the message in the meantime.
    func flashToast(_ message: String, for duration: Duration = .seconds(2), action: ToastAction? = nil) {
        toastToken &+= 1
        let token = toastToken
        toastMessage = message
        toastAction = action
        Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard let self, self.toastToken == token, self.toastMessage == message else { return }
            self.toastMessage = nil
            self.toastAction = nil
        }
    }

    func beginShortcutCapture() {
        shortcutCaptureDepth += 1
    }

    /// Never takes the depth below zero.
    func endShortcutCapture() {
        shortcutCaptureDepth = max(0, shortcutCaptureDepth - 1)
    }

    /// The recorder whose capture is open, or nil. A recorder that starts
    /// takes the capture over from any other, so recorders together hold at
    /// most one level of `shortcutCaptureDepth`, and a recorder that is no
    /// longer active must ignore key events.
    private(set) var activeShortcutRecorder: UUID?

    func beginShortcutCapture(recorder: UUID) {
        if activeShortcutRecorder == nil { beginShortcutCapture() }
        activeShortcutRecorder = recorder
    }

    /// Does nothing unless `recorder` holds the capture.
    func endShortcutCapture(recorder: UUID) {
        guard activeShortcutRecorder == recorder else { return }
        activeShortcutRecorder = nil
        endShortcutCapture()
    }
}
