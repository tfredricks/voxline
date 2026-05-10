// voxline/Pipeline/CapturePipeline.swift  (replace contents)
import Foundation

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

    init(
        state: AppState,
        capture: AudioCapturing,
        transcriber: Transcribing,
        llm: LLMServing,
        modes: ModeResolving,
        frontmost: FrontmostAppProviding,
        fieldInspector: FocusedFieldInspecting,
        injector: ClipboardInjecting
    ) {
        self.state = state
        self.capture = capture
        self.transcriber = transcriber
        self.llm = llm
        self.modes = modes
        self.frontmost = frontmost
        self.fieldInspector = fieldInspector
        self.injector = injector

        capture.onLevel = { [weak self] level in
            Task { @MainActor in
                guard let self else { return }
                self.state.audioLevel = level
                if level > self.state.debugLastPeakLevel {
                    self.state.debugLastPeakLevel = level
                }
            }
        }
        capture.onTapCallback = { [weak self] _ in
            Task { @MainActor in
                self?.state.debugLastTapCallbackCount += 1
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
            setError("Audio capture failed: \(error.localizedDescription)")
            return
        }
        state.recordingStartedAt = Date()
        state.audioLevel = 0
        state.debugLastPeakLevel = 0
        state.debugLastTapCallbackCount = 0
        // Scrub the prior dictation's text so it doesn't linger in process
        // memory (and the Debug window) for the lifetime of the app. Spoken
        // content can include passwords / 2FA codes / private notes; not a
        // hard secret leak, but a defensible-by-default hygiene measure.
        state.lastTranscript = nil
        state.lastCleanedText = nil
        state.status = .recording
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
        state.debugLastSampleCount = samples.count
        state.debugPipelinePhase = "stopped capture (\(samples.count) samples)"

        // Silent-capture detector: tap fired (samples non-empty) but no audio
        // signal reached the converter (peak stayed at 0). Almost always means
        // Microphone permission is denied or a muted device was selected.
        if !samples.isEmpty && state.debugLastPeakLevel == 0 {
            return setError("No audio captured. Check that Microphone permission is granted and the input device isn't muted.")
        }

        if samples.isEmpty {
            resetIdle()
            return
        }

        // 1. Transcribe locally.
        state.debugPipelinePhase = "transcribing"
        let transcript: String
        do {
            transcript = try await transcriber.transcribe(samples: samples)
        } catch {
            return setError("Transcription failed. Try again or pick a different model in Settings → General.")
        }
        state.lastTranscript = transcript

        if transcript.isEmpty {
            // Nothing to clean / paste — quietly idle out.
            resetIdle()
            return
        }

        // 2. Resolve the active mode by frontmost bundle ID + focused field
        //    snapshot. Falls back to `*` wildcard when nothing matches.
        let bundleID = frontmost.frontmostBundleID()
        let field = fieldInspector.inspect()
        guard let mode = modes.mode(for: bundleID, field: field) else {
            return setError("No mode for app '\(bundleID ?? "unknown")' and no '*' fallback configured. Open Settings → Modes.")
        }
        state.debugPipelinePhase = "llm (\(mode.displayName))"

        // 3. LLM cleanup.
        let cleaned: String
        do {
            cleaned = try await llm.cleanup(transcript: transcript, mode: mode)
        } catch let e as LLMError {
            return setError(e.errorDescription ?? "LLM cleanup failed.")
        } catch {
            return setError("LLM cleanup failed: \(error.localizedDescription)")
        }
        state.lastCleanedText = cleaned

        // 4. Paste.
        state.debugPipelinePhase = "pasting"
        do {
            let outcome = try await injector.inject(cleaned)
            state.debugLastInsertionResult = outcome.description
        } catch let e as TextInsertionError {
            let category: AppErrorCategory = (e == .accessibilityNotGranted) ? .permissions : .pipeline
            return setError(e.errorDescription ?? "Text insertion failed.", category: category)
        } catch {
            return setError("Text insertion failed: \(error.localizedDescription)")
        }

        resetIdle()
    }

    private func resetIdle() {
        state.recordingStartedAt = nil
        state.audioLevel = 0
        state.status = .idle
        state.debugPipelinePhase = "idle"
    }

    private func setError(_ message: String, category: AppErrorCategory = .pipeline) {
        state.status = .error(category: category, message: message)
        state.recordingStartedAt = nil
        state.audioLevel = 0
        state.debugPipelinePhase = "error"
    }
}
