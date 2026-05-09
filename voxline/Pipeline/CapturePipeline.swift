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
    private let modes: ModeResolving
    private let frontmost: FrontmostAppProviding
    private let injector: ClipboardInjecting

    init(
        state: AppState,
        capture: AudioCapturing,
        transcriber: Transcribing,
        llm: LLMServing,
        modes: ModeResolving,
        frontmost: FrontmostAppProviding,
        injector: ClipboardInjecting
    ) {
        self.state = state
        self.capture = capture
        self.transcriber = transcriber
        self.llm = llm
        self.modes = modes
        self.frontmost = frontmost
        self.injector = injector

        capture.onLevel = { [weak self] level in
            Task { @MainActor in self?.state.audioLevel = level }
        }
    }

    /// Begin a new recording. Caller must ensure we're not already recording.
    func startRecording() {
        if state.status.blocksRecording { return }
        do {
            try capture.start()
        } catch {
            state.status = .error("Audio capture failed: \(error.localizedDescription)")
            state.recordingStartedAt = nil
            state.audioLevel = 0
            return
        }
        state.recordingStartedAt = Date()
        state.audioLevel = 0
        state.status = .recording
    }

    /// Stop capture, transcribe, run LLM cleanup against the active mode's
    /// prompt, and paste the result into the focused field.
    func finalizeRecording() async {
        if state.status.blocksRecording { return }
        capture.stop()
        let samples = capture.takeSamples()
        state.status = .thinking

        if samples.isEmpty {
            resetIdle()
            return
        }

        // 1. Transcribe locally.
        let transcript: String
        do {
            transcript = try await transcriber.transcribe(samples: samples)
        } catch {
            return setError("Transcription failed: \(error.localizedDescription)")
        }
        state.lastTranscript = transcript

        if transcript.isEmpty {
            // Nothing to clean / paste — quietly idle out.
            resetIdle()
            return
        }

        // 2. Resolve the active mode by frontmost bundle ID. Falls back to
        //    `*` wildcard when nothing matches.
        let bundleID = frontmost.frontmostBundleID()
        guard let mode = modes.mode(for: bundleID) else {
            return setError("No mode for app '\(bundleID ?? "unknown")' and no '*' fallback configured. Open Settings → Modes.")
        }

        // 3. LLM cleanup.
        let cleaned: String
        do {
            cleaned = try await llm.cleanup(transcript: transcript, mode: mode)
        } catch let e as LLMError {
            return setError(e.errorDescription ?? "LLM cleanup failed.")
        } catch {
            return setError("LLM cleanup failed: \(error.localizedDescription)")
        }

        // 4. Paste.
        do {
            try await injector.inject(cleaned)
        } catch {
            return setError("Paste failed: \(error.localizedDescription)")
        }

        resetIdle()
    }

    private func resetIdle() {
        state.recordingStartedAt = nil
        state.audioLevel = 0
        state.status = .idle
    }

    private func setError(_ message: String) {
        state.status = .error(message)
        state.recordingStartedAt = nil
        state.audioLevel = 0
    }
}
