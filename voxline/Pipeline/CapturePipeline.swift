import Foundation

/// Coordinates the hotkey → audio capture → transcription pipeline.
/// Updates AppState along the way.
@MainActor
final class CapturePipeline {

    private let state: AppState
    private let capture: AudioCapturing
    private let transcriber: Transcribing

    init(state: AppState, capture: AudioCapturing, transcriber: Transcribing) {
        self.state = state
        self.capture = capture
        self.transcriber = transcriber

        capture.onLevel = { [weak self] level in
            Task { @MainActor in self?.state.audioLevel = level }
        }
    }

    /// Begin a new recording. Caller must ensure we're not already recording.
    func startRecording() {
        do {
            try capture.start()
        } catch {
            state.status = .error("Audio capture failed: \(error.localizedDescription)")
            return
        }
        state.recordingStartedAt = Date()
        state.audioLevel = 0
        state.status = .recording
    }

    /// Stop capture, transcribe what was captured, write transcript to state.
    func finalizeRecording() async {
        capture.stop()
        let samples = capture.takeSamples()
        state.status = .thinking

        if samples.isEmpty {
            // Nothing captured — quietly return to idle.
            resetIdle()
            return
        }

        do {
            let text = try await transcriber.transcribe(samples: samples)
            state.lastTranscript = text
        } catch {
            state.status = .error("Transcription failed: \(error.localizedDescription)")
            state.recordingStartedAt = nil
            state.audioLevel = 0
            return
        }

        resetIdle()
    }

    private func resetIdle() {
        state.recordingStartedAt = nil
        state.audioLevel = 0
        state.status = .idle
    }
}
