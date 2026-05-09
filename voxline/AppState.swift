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

    // MARK: - Debug diagnostics (rendered in the menu-bar Debug section)

    /// Current `HotkeyStateMachine.State`, stringified. Updated by HotkeyMonitor
    /// after every state transition, so a stuck state (e.g. `.recording` or
    /// `.finalizing` while the user isn't holding the chord) is immediately visible.
    var debugHotkeyState: String = "idle"

    /// Whether the CGEventTap is currently installed and active.
    var debugTapInstalled: Bool = false

    /// Most recent pipeline phase. Set by CapturePipeline.finalizeRecording
    /// at each step ("idle" → "transcribing" → "llm" → "paste" → "idle").
    /// If finalize hangs, this is the last phase it reached.
    var debugPipelinePhase: String = "idle"

    /// Live permission states polled by the debug-screen watchdog.
    var debugMicrophoneStatus: String = "?"
    var debugAccessibilityStatus: String = "?"
    var debugInputMonitoringStatus: String = "?"

    /// Last log line emitted by the debug screen's manual test buttons.
    /// Empty string when nothing has been run yet.
    var debugLastTestResult: String = ""

    /// Peak audio level observed during the most recent recording. Stays
    /// at 0 if the mic was muted/denied or the input device produced silence.
    var debugLastPeakLevel: Float = 0

    /// Number of 16 kHz mono Float32 samples handed to WhisperKit at the end
    /// of the most recent recording. ~16,000 = 1 second of audio.
    var debugLastSampleCount: Int = 0
}
