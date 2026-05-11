import Foundation
import Observation

/// Distinguishes who set the current error so consumers can decide whether
/// to clear it. Without this tag, the AppCoordinator's reconcile loop
/// clobbered transient pipeline errors when permissions came back, and a
/// chord-press silently cleared a sticky permissions banner. Adding the
/// category keeps each owner responsible for clearing only its own errors.
enum AppErrorCategory: Equatable {
    /// Hotkey accessibility / Input Monitoring revoked, or first-launch
    /// permissions not yet granted. Sticky until permissions are restored.
    /// Cleared by AppCoordinator's reconcile loop when the tap installs.
    case permissions
    /// Transient dictation failure (audio capture, transcription, LLM,
    /// paste, mode-missing, silent-mic). Cleared by the next chord press
    /// (the user retrying).
    case pipeline
    /// Whisper model download or prewarm failure. Cleared by the next
    /// successful prep run.
    case modelPrep
}

enum AppStatus: Equatable {
    case idle
    case recording
    case thinking
    /// First-run model fetch in progress. `progress` is in [0, 1].
    case downloadingModel(progress: Double)
    /// Model files are on disk but Core ML / Apple Neural Engine is still
    /// compiling them. The first run after download can take 30s-2min.
    case preparingModel
    case error(category: AppErrorCategory, message: String)

    /// Recording is blocked until the model is fully ready.
    var blocksRecording: Bool {
        switch self {
        case .downloadingModel, .preparingModel: return true
        default: return false
        }
    }
}

@Observable
@MainActor
final class AppState {
    var status: AppStatus = .idle
    var hotkeyEnabled: Bool = true

    /// Live mic input level while recording, in [0, 1]. Used by the
    /// recording-pill waveform. Updated from the audio thread.
    var audioLevel: Float = 0

    /// Most recently produced raw (pre-cleanup) transcript. Set by
    /// CapturePipeline as a debug aid — the pasted text is the LLM-cleaned
    /// version, not this string.
    var lastTranscript: String?

    /// Most recently produced LLM-cleaned text — i.e. exactly what was (or
    /// would have been) pasted into the focused field. Populated by
    /// CapturePipeline after the LLM step completes and before the paste
    /// step runs, so it is visible in the Debug window even when paste fails.
    var lastCleanedText: String?

    /// Wall-clock time the current recording began, or nil while idle.
    /// Used for the pill's elapsed-time display and for the max-duration fail-safe.
    var recordingStartedAt: Date?

    /// Peak audio level observed during the most recent recording. Stays
    /// at 0 if the mic was muted/denied or the input device produced silence.
    /// Read by CapturePipeline's silent-capture detector (not debug-only) and
    /// rendered in the Debug window's Last-attempt panel.
    var lastPeakLevel: Float = 0

    /// Duration of the most recent recording in seconds, derived from the
    /// sample count delivered to WhisperKit (samples / 16_000). Nil until the
    /// first recording finalizes.
    var lastRecordingDuration: TimeInterval?

    /// Wall-clock seconds spent in the local WhisperKit transcribe call on
    /// the most recent dictation. Nil until the first transcribe completes.
    var lastTranscribeDuration: TimeInterval?

    /// Wall-clock seconds spent in the LLM cleanup call on the most recent
    /// dictation. Nil until the first cleanup completes (or skipped when the
    /// transcript was empty).
    var lastCleanupDuration: TimeInterval?

    // MARK: - Debug diagnostics (rendered in the Debug window)

    /// Current `HotkeyStateMachine.State`, stringified. Updated by HotkeyMonitor
    /// after every state transition, so a stuck state (e.g. `.recording` or
    /// `.finalizing` while the user isn't holding the chord) is immediately visible.
    var debugHotkeyState: String = "idle"

    /// Whether the CGEventTap is currently installed and active.
    var debugTapInstalled: Bool = false

    /// Last insertion strategy used by ClipboardInjector, including whether
    /// AX could confirm that the focused field changed.
    var debugLastInsertionResult: String = "(none yet)"

    /// Live permission states polled by the debug-screen watchdog.
    var debugMicrophoneStatus: String = "?"
    var debugAccessibilityStatus: String = "?"
    var debugInputMonitoringStatus: String = "?"

    /// Last log line emitted by the debug screen's manual test buttons.
    /// Empty string when nothing has been run yet.
    var debugLastTestResult: String = ""

    /// Why finalize ran on the most recent chord cycle. Set by HotkeyMonitor
    /// the moment finalize is triggered, so a too-short recording explains
    /// itself: chord-release vs app-deactivated vs tap-disabled vs max-duration.
    var debugLastFinalizeReason: String = "(none yet)"
}
