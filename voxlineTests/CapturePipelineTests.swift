// voxlineTests/CapturePipelineTests.swift  (replace contents)
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

    final class FakeLLM: LLMServing, @unchecked Sendable {
        var nextResult: Result<String, Error> = .success("cleaned")
        var calls: [(transcript: String, mode: Mode)] = []
        func cleanup(transcript: String, mode: Mode) async throws -> String {
            calls.append((transcript, mode))
            return try nextResult.get()
        }
    }

    final class FakeFrontmost: FrontmostAppProviding, @unchecked Sendable {
        var bundleID: String?
        func frontmostBundleID() -> String? { bundleID }
    }

    final class FakeInjector: ClipboardInjecting {
        var injected: [String] = []
        var nextError: Error?
        func inject(_ text: String) async throws {
            if let nextError { throw nextError }
            injected.append(text)
        }
    }

    private func makePipeline(
        frontmostBundleID: String? = "com.tinyspeck.slackmacgap",
        modes: [Mode] = [
            Mode(bundleID: "com.tinyspeck.slackmacgap", displayName: "Slack", prompt: "slack-prompt", model: nil, temperature: nil),
            Mode(bundleID: "*", displayName: "Default", prompt: "default-prompt", model: nil, temperature: nil)
        ]
    ) -> (pipe: CapturePipeline, state: AppState, capture: FakeCapture, transcriber: FakeTranscriber, llm: FakeLLM, frontmost: FakeFrontmost, injector: FakeInjector) {
        let state = AppState()
        let capture = FakeCapture()
        let transcriber = FakeTranscriber()
        let llm = FakeLLM()
        let front = FakeFrontmost(); front.bundleID = frontmostBundleID
        let injector = FakeInjector()
        let router = ModeRouter(modes: modes)
        let pipe = CapturePipeline(
            state: state, capture: capture, transcriber: transcriber,
            llm: llm, modes: router, frontmost: front, injector: injector
        )
        return (pipe, state, capture, transcriber, llm, front, injector)
    }

    @Test func startRecording_setsStateAndStartsCapture() {
        let (pipe, state, capture, _, _, _, _) = makePipeline()
        pipe.startRecording()
        #expect(state.status == .recording)
        #expect(state.recordingStartedAt != nil)
        #expect(capture.startCallCount == 1)
    }

    @Test func finalizeRecording_routesViaModeAndCallsLLMAndPastes() async throws {
        let (pipe, state, _, transcriber, llm, _, injector) = makePipeline()
        transcriber.nextResult = .success("uh hello there")
        llm.nextResult = .success("Hello there.")
        pipe.startRecording()
        await pipe.finalizeRecording()

        #expect(transcriber.transcribeCallCount == 1)
        #expect(llm.calls.count == 1)
        #expect(llm.calls[0].transcript == "uh hello there")
        #expect(llm.calls[0].mode.bundleID == "com.tinyspeck.slackmacgap")
        #expect(injector.injected == ["Hello there."])
        #expect(state.status == .idle)
        #expect(state.lastTranscript == "uh hello there")
    }

    @Test func unknown_bundleID_falls_back_to_wildcard_mode() async throws {
        let (pipe, _, _, _, llm, _, _) = makePipeline(frontmostBundleID: "com.unknown.app")
        pipe.startRecording()
        await pipe.finalizeRecording()
        #expect(llm.calls[0].mode.bundleID == "*")
    }

    @Test func transcriptionFailure_setsErrorStateNoLLMNoPaste() async throws {
        struct StubError: Error {}
        let (pipe, state, _, transcriber, llm, _, injector) = makePipeline()
        transcriber.nextResult = .failure(StubError())
        pipe.startRecording()
        await pipe.finalizeRecording()
        if case .error = state.status { } else { Issue.record("expected .error") }
        #expect(llm.calls.isEmpty)
        #expect(injector.injected.isEmpty)
    }

    @Test func empty_transcript_skips_llm_and_paste() async throws {
        let (pipe, state, _, transcriber, llm, _, injector) = makePipeline()
        transcriber.nextResult = .success("")
        pipe.startRecording()
        await pipe.finalizeRecording()
        #expect(llm.calls.isEmpty)
        #expect(injector.injected.isEmpty)
        #expect(state.status == .idle)
    }

    @Test func llm_missingAPIKey_surfacesActionableErrorMessage() async throws {
        let (pipe, state, _, _, llm, _, _) = makePipeline()
        llm.nextResult = .failure(LLMError.missingAPIKey)
        pipe.startRecording()
        await pipe.finalizeRecording()
        if case .error(let msg) = state.status {
            #expect(msg.contains("Settings"))
        } else {
            Issue.record("expected .error")
        }
    }

    @Test func paste_failure_setsErrorState() async throws {
        struct StubError: Error {}
        let (pipe, state, _, _, _, _, injector) = makePipeline()
        injector.nextError = StubError()
        pipe.startRecording()
        await pipe.finalizeRecording()
        if case .error = state.status { } else { Issue.record("expected .error") }
    }

    @Test func startRecording_skipsWhenDownloadingModel() {
        let (pipe, state, capture, _, _, _, _) = makePipeline()
        state.status = .downloadingModel(progress: 0.3)
        pipe.startRecording()
        #expect(capture.startCallCount == 0)
    }

    @Test func startRecording_skipsWhenPreparingModel() {
        let (pipe, state, capture, _, _, _, _) = makePipeline()
        state.status = .preparingModel
        pipe.startRecording()
        #expect(capture.startCallCount == 0)
    }
}
