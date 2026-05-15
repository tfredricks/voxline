import Foundation
import OSLog

/// Coordinates the hotkey → audio capture → transcription → LLM cleanup →
/// clipboard inject pipeline. Updates AppState along the way.
@MainActor
final class CapturePipeline {

    private let state: AppState
    private let capture: AudioCapturing
    private let transcriber: Transcribing
    private let llm: LLMServing
    var modes: ModeRouter
    private let frontmost: FrontmostAppProviding
    private let fieldInspector: FocusedFieldInspecting
    private let injector: ClipboardInjecting
    private let historyStore: DictationHistoryStore
    private let contextCapture: ContextCapturing
    private var contextTask: Task<CapturedContext, Never>?

    init(
        state: AppState,
        capture: AudioCapturing,
        transcriber: Transcribing,
        llm: LLMServing,
        modes: ModeRouter,
        frontmost: FrontmostAppProviding,
        fieldInspector: FocusedFieldInspecting,
        injector: ClipboardInjecting,
        historyStore: DictationHistoryStore,
        contextCapture: ContextCapturing
    ) {
        self.state = state
        self.capture = capture
        self.transcriber = transcriber
        self.llm = llm
        self.modes = modes
        self.frontmost = frontmost
        self.fieldInspector = fieldInspector
        self.injector = injector
        self.historyStore = historyStore
        self.contextCapture = contextCapture

        capture.onLevel = { [weak self] level in
            Task { @MainActor in
                guard let self else { return }
                self.state.audioLevel = level
                if level > self.state.lastPeakLevel {
                    self.state.lastPeakLevel = level
                }
            }
        }
    }

    /// Begin a new recording. Caller must ensure we're not already recording.
    func startRecording() {
        // Reject re-entry while a recording or its post-recording pipeline
        // (transcribe → LLM → paste) is still in flight. `.thinking` covers
        // the entire await chain in finalizeRecording — `state.status` is set
        // to `.thinking` synchronously before any await, so a second call
        // landing on MainActor sees it.
        //
        // Permissions errors are sticky: clearing them on a chord-press
        // would mask a real "tap is uninstalled" condition. Pipeline and
        // modelPrep errors are clearable by the user retrying.
        switch state.status {
        case .recording, .thinking, .downloadingModel, .preparingModel, .permissionsError:
            return
        case .idle, .error:
            break
        }
        do {
            try capture.start()
        } catch {
            AppLog.pipeline.error("capture.start failed: \(error.localizedDescription)")
            setError("Audio capture failed: \(error.localizedDescription)")
            return
        }
        AppLog.pipeline.debug("recording started")
        state.recordingStartedAt = Date()
        state.audioLevel = 0
        state.lastPeakLevel = 0
        // Scrub the prior dictation's text so it doesn't linger in process
        // memory for the lifetime of the app. Spoken content can include
        // passwords / 2FA codes / private notes; defensible-by-default hygiene.
        state.lastTranscript = nil
        state.lastCleanedText = nil
        state.lastTranscribeDuration = nil
        state.lastCleanupDuration = nil
        state.status = .recording
        let captor = contextCapture
        contextTask = Task.detached(priority: .userInitiated) {
            await captor.capture()
        }
    }

    /// Stop capture, transcribe, run LLM cleanup against the active mode's
    /// prompt, and paste the result into the focused field.
    func finalizeRecording() async {
        // Only valid entry state is `.recording`. A spurious finalize while
        // we're already in `.thinking` (an earlier finalize is mid-flight) or
        // any non-recording state would race with the in-flight pipeline.
        guard case .recording = state.status else { return }
        capture.stop()
        let samples = capture.takeSamples()
        state.status = .thinking
        state.lastRecordingDuration = Double(samples.count) / 16_000.0
        AppLog.pipeline.info("recording stopped: samples=\(samples.count) duration=\(self.state.lastRecordingDuration ?? 0)s peak=\(self.state.lastPeakLevel)")

        // Silent-capture detector: tap fired (samples non-empty) but no audio
        // signal reached the converter (peak stayed at 0). Almost always means
        // Microphone permission is denied or a muted device was selected.
        if !samples.isEmpty && state.lastPeakLevel == 0 {
            AppLog.pipeline.error("silent capture: samples present but peak=0 (mic permission or muted device)")
            contextTask?.cancel(); contextTask = nil
            return setError("No audio captured. Check that Microphone permission is granted and the input device isn't muted.")
        }

        if samples.isEmpty {
            AppLog.pipeline.debug("empty capture, idling out")
            contextTask?.cancel(); contextTask = nil
            resetIdle()
            return
        }

        // 1. Transcribe locally.
        let transcript: String
        let transcribeStart = Date()
        do {
            transcript = try await transcriber.transcribe(samples: samples)
        } catch {
            AppLog.whisper.error("transcribe failed: \(error.localizedDescription)")
            contextTask?.cancel(); contextTask = nil
            return setError("Transcription failed. Try again or pick a different model in Settings → General.")
        }
        state.lastTranscribeDuration = Date().timeIntervalSince(transcribeStart)
        state.lastTranscript = transcript
        AppLog.whisper.info("transcribed: chars=\(transcript.count) duration=\(self.state.lastTranscribeDuration ?? 0)s")

        if transcript.isEmpty {
            // Nothing to clean / paste — quietly idle out.
            contextTask?.cancel(); contextTask = nil
            resetIdle()
            return
        }

        // 2. Resolve the active mode by frontmost bundle ID + focused field
        //    snapshot. Falls back to `*` wildcard when nothing matches.
        let bundleID = frontmost.frontmostBundleID()
        let field = fieldInspector.inspect()
        guard let mode = modes.mode(for: bundleID, field: field) else {
            AppLog.pipeline.error("no mode for bundle=\(bundleID ?? "unknown")")
            contextTask?.cancel(); contextTask = nil
            return setError("No mode for app '\(bundleID ?? "unknown")' and no '*' fallback configured. Open Settings → Modes.")
        }
        AppLog.pipeline.info("mode resolved: bundle=\(bundleID ?? "unknown") mode=\(mode.displayName)")

        // 3. LLM cleanup.
        let context = await contextTask?.value ?? .empty
        contextTask = nil
        AppLog.context.debug("context: app=\(context.appName ?? "nil") bundle=\(context.bundleID ?? "nil") secure=\(context.isSecureField) durationMs=\(context.captureDurationMs) notes=\(context.captureNotes.joined(separator: ","))")
        if !context.captureNotes.isEmpty {
            AppLog.context.info("context partial: notes=\(context.captureNotes.joined(separator: ",")) durationMs=\(context.captureDurationMs)")
        }
        let cleaned: String
        let cleanupStart = Date()
        do {
            cleaned = try await llm.cleanup(transcript: transcript, mode: mode, context: context)
        } catch let e as LLMError {
            AppLog.llm.error("cleanup failed: \(e.errorDescription ?? "unknown")")
            return setError(e.errorDescription ?? "LLM cleanup failed.")
        } catch {
            AppLog.llm.error("cleanup failed: \(error.localizedDescription)")
            return setError("LLM cleanup failed: \(error.localizedDescription)")
        }
        state.lastCleanupDuration = Date().timeIntervalSince(cleanupStart)
        state.lastCleanedText = cleaned
        historyStore.record(cleanedText: cleaned, mode: mode, context: context)
        AppLog.llm.info("cleanup ok: in=\(transcript.count) out=\(cleaned.count) duration=\(self.state.lastCleanupDuration ?? 0)s")

        // 4. Paste.
        do {
            let outcome = try await injector.inject(cleaned)
            AppLog.paste.info("inject ok: outcome=\(outcome.description)")
        } catch let e as TextInsertionError {
            AppLog.paste.error("inject failed: \(e.errorDescription ?? "unknown")")
            return setError(e.errorDescription ?? "Text insertion failed.", permissions: e == .accessibilityNotGranted)
        } catch {
            AppLog.paste.error("inject failed: \(error.localizedDescription)")
            return setError("Text insertion failed: \(error.localizedDescription)")
        }

        resetIdle()
    }

    private func resetIdle() {
        state.recordingStartedAt = nil
        state.audioLevel = 0
        state.status = .idle
    }

    private func setError(_ message: String, permissions: Bool = false) {
        state.status = permissions ? .permissionsError(message) : .error(message)
        state.recordingStartedAt = nil
        state.audioLevel = 0
    }
}
