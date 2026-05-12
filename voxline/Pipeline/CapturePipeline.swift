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
    var modes: ModeResolving
    private let frontmost: FrontmostAppProviding
    private let fieldInspector: FocusedFieldInspecting
    private let injector: ClipboardInjecting
    private let historyStore: DictationHistoryStore
    private let contextCapture: ContextCapturing
    private let vocabularyStore: CustomVocabularyStore
    private var contextTask: Task<CapturedContext, Never>?

    init(
        state: AppState,
        capture: AudioCapturing,
        transcriber: Transcribing,
        llm: LLMServing,
        modes: ModeResolving,
        frontmost: FrontmostAppProviding,
        fieldInspector: FocusedFieldInspecting,
        injector: ClipboardInjecting,
        historyStore: DictationHistoryStore,
        contextCapture: ContextCapturing,
        vocabularyStore: CustomVocabularyStore
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
        self.vocabularyStore = vocabularyStore

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
        case .recording, .thinking, .downloadingModel, .preparingModel:
            return
        case .error(.permissions, _):
            return
        case .idle, .error:
            break
        }
        do {
            try capture.start()
        } catch {
            AppLog.pipeline.error("capture.start failed: \(error.localizedDescription, privacy: .public)")
            setError("Audio capture failed: \(error.localizedDescription)")
            return
        }
        AppLog.pipeline.debug("recording started")
        state.recordingStartedAt = Date()
        state.audioLevel = 0
        state.lastPeakLevel = 0
        // Scrub the prior dictation's text so it doesn't linger in process
        // memory (and the Debug window) for the lifetime of the app. Spoken
        // content can include passwords / 2FA codes / private notes; not a
        // hard secret leak, but a defensible-by-default hygiene measure.
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
        AppLog.pipeline.info("recording stopped: samples=\(samples.count, privacy: .public) duration=\(self.state.lastRecordingDuration ?? 0, privacy: .public)s peak=\(self.state.lastPeakLevel, privacy: .public)")

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

        let signposter = AppLog.pipelineSignposter
        let sessionID = signposter.makeSignpostID()
        let sessionInterval = signposter.beginInterval("session", id: sessionID)

        // 1. Transcribe locally.
        let transcript: String
        let transcribeInterval = signposter.beginInterval("transcribe", id: sessionID)
        let transcribeStart = Date()
        do {
            // Read vocab synchronously off the store. Cheap (single
            // UserDefaults read). ContextCaptureService reads the same list
            // onto the captured context, so the same terms reach LLM
            // cleanup; the two reads are independent and may briefly differ
            // if the user edited the list between them — not worth
            // coordinating.
            let vocab = vocabularyStore.load()
            transcript = try await transcriber.transcribe(samples: samples, vocabulary: vocab)
            signposter.endInterval("transcribe", transcribeInterval)
        } catch {
            signposter.endInterval("transcribe", transcribeInterval, "error")
            signposter.endInterval("session", sessionInterval, "error")
            AppLog.whisper.error("transcribe failed: \(error.localizedDescription, privacy: .public)")
            contextTask?.cancel(); contextTask = nil
            return setError("Transcription failed. Try again or pick a different model in Settings → General.")
        }
        state.lastTranscribeDuration = Date().timeIntervalSince(transcribeStart)
        state.lastTranscript = transcript
        AppLog.whisper.info("transcribed: chars=\(transcript.count, privacy: .public) duration=\(self.state.lastTranscribeDuration ?? 0, privacy: .public)s")

        if transcript.isEmpty {
            // Nothing to clean / paste — quietly idle out.
            signposter.endInterval("session", sessionInterval, "empty")
            contextTask?.cancel(); contextTask = nil
            resetIdle()
            return
        }

        // 2. Resolve the active mode by frontmost bundle ID + focused field
        //    snapshot. Falls back to `*` wildcard when nothing matches.
        let bundleID = frontmost.frontmostBundleID()
        let field = fieldInspector.inspect()
        guard let mode = modes.mode(for: bundleID, field: field) else {
            signposter.endInterval("session", sessionInterval, "no-mode")
            AppLog.pipeline.error("no mode for bundle=\(bundleID ?? "unknown", privacy: .public)")
            contextTask?.cancel(); contextTask = nil
            return setError("No mode for app '\(bundleID ?? "unknown")' and no '*' fallback configured. Open Settings → Modes.")
        }
        AppLog.pipeline.debug("mode resolved: bundle=\(bundleID ?? "unknown", privacy: .public) mode=\(mode.displayName, privacy: .private)")

        // 3. LLM cleanup.
        let context = await contextTask?.value ?? .empty
        contextTask = nil
        AppLog.context.debug("context: app=\(context.appName ?? "nil", privacy: .private) bundle=\(context.bundleID ?? "nil", privacy: .public) secure=\(context.isSecureField, privacy: .public) durationMs=\(context.captureDurationMs, privacy: .public) notes=\(context.captureNotes.joined(separator: ","), privacy: .public)")
        let cleaned: String
        let cleanupInterval = signposter.beginInterval("llm", id: sessionID)
        let cleanupStart = Date()
        do {
            cleaned = try await llm.cleanup(transcript: transcript, mode: mode, context: context)
            signposter.endInterval("llm", cleanupInterval)
        } catch let e as LLMError {
            signposter.endInterval("llm", cleanupInterval, "error")
            signposter.endInterval("session", sessionInterval, "error")
            AppLog.llm.error("cleanup failed: \(e.errorDescription ?? "unknown", privacy: .public)")
            return setError(e.errorDescription ?? "LLM cleanup failed.")
        } catch {
            signposter.endInterval("llm", cleanupInterval, "error")
            signposter.endInterval("session", sessionInterval, "error")
            AppLog.llm.error("cleanup failed: \(error.localizedDescription, privacy: .public)")
            return setError("LLM cleanup failed: \(error.localizedDescription)")
        }
        state.lastCleanupDuration = Date().timeIntervalSince(cleanupStart)
        state.lastCleanedText = cleaned
        historyStore.record(cleanedText: cleaned, mode: mode, context: context)
        AppLog.llm.info("cleanup ok: in=\(transcript.count, privacy: .public) out=\(cleaned.count, privacy: .public) duration=\(self.state.lastCleanupDuration ?? 0, privacy: .public)s")

        // 4. Paste.
        let pasteInterval = signposter.beginInterval("paste", id: sessionID)
        do {
            let outcome = try await injector.inject(cleaned)
            state.debugLastInsertionResult = outcome.description
            signposter.endInterval("paste", pasteInterval)
            AppLog.paste.debug("inject ok: outcome=\(outcome.description, privacy: .public)")
        } catch let e as TextInsertionError {
            signposter.endInterval("paste", pasteInterval, "error")
            signposter.endInterval("session", sessionInterval, "error")
            let category: AppErrorCategory = (e == .accessibilityNotGranted) ? .permissions : .pipeline
            AppLog.paste.error("inject failed: \(e.errorDescription ?? "unknown", privacy: .public)")
            return setError(e.errorDescription ?? "Text insertion failed.", category: category)
        } catch {
            signposter.endInterval("paste", pasteInterval, "error")
            signposter.endInterval("session", sessionInterval, "error")
            AppLog.paste.error("inject failed: \(error.localizedDescription, privacy: .public)")
            return setError("Text insertion failed: \(error.localizedDescription)")
        }

        signposter.endInterval("session", sessionInterval)
        resetIdle()
    }

    private func resetIdle() {
        state.recordingStartedAt = nil
        state.audioLevel = 0
        state.status = .idle
    }

    private func setError(_ message: String, category: AppErrorCategory = .pipeline) {
        state.status = .error(category: category, message: message)
        state.recordingStartedAt = nil
        state.audioLevel = 0
    }
}
