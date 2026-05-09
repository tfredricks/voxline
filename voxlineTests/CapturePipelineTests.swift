import Testing
import Foundation
@testable import voxline

@Suite @MainActor struct CapturePipelineTests {

    final class FakeCapture: AudioCapturing {
        var onLevel: ((Float) -> Void)?
        var startCallCount = 0
        var stopCallCount = 0
        var pendingSamples: [Float] = [0.1, 0.2, 0.3]
        func start() throws { startCallCount += 1 }
        func stop() { stopCallCount += 1 }
        func takeSamples() -> [Float] { defer { pendingSamples = [] }; return pendingSamples }
    }

    final class FakeTranscriber: Transcribing {
        var nextResult: Result<String, Error> = .success("hello world")
        var transcribeCallCount = 0
        func transcribe(samples: [Float]) async throws -> String {
            transcribeCallCount += 1
            return try nextResult.get()
        }
    }

    @Test func startRecording_setsStateAndStartsCapture() async throws {
        let state = AppState()
        let capture = FakeCapture()
        let transcriber = FakeTranscriber()
        let pipeline = CapturePipeline(state: state, capture: capture, transcriber: transcriber)

        pipeline.startRecording()

        #expect(state.status == .recording)
        #expect(state.recordingStartedAt != nil)
        #expect(capture.startCallCount == 1)
    }

    @Test func finalizeRecording_transcribesAndUpdatesState() async throws {
        let state = AppState()
        let capture = FakeCapture()
        let transcriber = FakeTranscriber()
        transcriber.nextResult = .success("captured text")
        let pipeline = CapturePipeline(state: state, capture: capture, transcriber: transcriber)

        pipeline.startRecording()
        await pipeline.finalizeRecording()

        #expect(capture.stopCallCount == 1)
        #expect(transcriber.transcribeCallCount == 1)
        #expect(state.lastTranscript == "captured text")
        #expect(state.status == .idle)
        #expect(state.recordingStartedAt == nil)
    }

    @Test func startRecording_skipsWhenDownloadingModel() throws {
        let state = AppState()
        state.status = .downloadingModel(progress: 0.3)
        let capture = FakeCapture()
        let transcriber = FakeTranscriber()
        let pipeline = CapturePipeline(state: state, capture: capture, transcriber: transcriber)

        pipeline.startRecording()

        #expect(capture.startCallCount == 0)
        #expect(state.status == .downloadingModel(progress: 0.3))
        #expect(state.recordingStartedAt == nil)
    }

    @Test func finalizeRecording_skipsWhenDownloadingModel() async {
        let state = AppState()
        state.status = .downloadingModel(progress: 0.3)
        let capture = FakeCapture()
        let transcriber = FakeTranscriber()
        let pipeline = CapturePipeline(state: state, capture: capture, transcriber: transcriber)

        await pipeline.finalizeRecording()

        #expect(capture.stopCallCount == 0)
        #expect(transcriber.transcribeCallCount == 0)
        #expect(state.status == .downloadingModel(progress: 0.3))
    }

    @Test func transcriptionFailure_setsErrorState() async throws {
        struct StubError: Error {}

        let state = AppState()
        let capture = FakeCapture()
        let transcriber = FakeTranscriber()
        transcriber.nextResult = .failure(StubError())
        let pipeline = CapturePipeline(state: state, capture: capture, transcriber: transcriber)

        pipeline.startRecording()
        await pipeline.finalizeRecording()

        if case .error = state.status {
            // ok
        } else {
            Issue.record("expected .error state, got \(state.status)")
        }
    }
}
