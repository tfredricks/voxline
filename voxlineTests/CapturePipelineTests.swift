// voxlineTests/CapturePipelineTests.swift  (replace contents)
import Testing
import Foundation
@testable import voxline

@Suite @MainActor struct CapturePipelineTests {

    final class FakeCapture: AudioCapturing {
        var onLevel: ((Float) -> Void)?
        var onTapCallback: ((Int) -> Void)?
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
        func inject(_ text: String) async throws -> TextInsertionOutcome {
            if let nextError { throw nextError }
            injected.append(text)
            return TextInsertionOutcome(strategy: .clipboardPaste, verification: .unverified)
        }
    }

    /// Start recording then finalize, simulating the production `onLevel`
    /// callback firing so the silent-capture detector doesn't fire.
    private func startAndFinalize(_ pipe: CapturePipeline, state: AppState) async {
        pipe.startRecording()
        state.debugLastPeakLevel = 0.5
        await pipe.finalizeRecording()
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
        await startAndFinalize(pipe, state: state)

        #expect(transcriber.transcribeCallCount == 1)
        #expect(llm.calls.count == 1)
        #expect(llm.calls[0].transcript == "uh hello there")
        #expect(llm.calls[0].mode.bundleID == "com.tinyspeck.slackmacgap")
        #expect(injector.injected == ["Hello there."])
        #expect(state.status == .idle)
        #expect(state.lastTranscript == "uh hello there")
    }

    @Test func unknown_bundleID_falls_back_to_wildcard_mode() async throws {
        let (pipe, state, _, _, llm, _, _) = makePipeline(frontmostBundleID: "com.unknown.app")
        await startAndFinalize(pipe, state: state)
        #expect(llm.calls[0].mode.bundleID == "*")
    }

    @Test func transcriptionFailure_setsErrorStateNoLLMNoPaste() async throws {
        struct StubError: Error {}
        let (pipe, state, _, transcriber, llm, _, injector) = makePipeline()
        transcriber.nextResult = .failure(StubError())
        await startAndFinalize(pipe, state: state)
        if case .error = state.status { } else { Issue.record("expected .error") }
        #expect(llm.calls.isEmpty)
        #expect(injector.injected.isEmpty)
    }

    @Test func empty_transcript_skips_llm_and_paste() async throws {
        let (pipe, state, _, transcriber, llm, _, injector) = makePipeline()
        transcriber.nextResult = .success("")
        await startAndFinalize(pipe, state: state)
        #expect(llm.calls.isEmpty)
        #expect(injector.injected.isEmpty)
        #expect(state.status == .idle)
    }

    @Test func llm_missingAPIKey_surfacesActionableErrorMessage() async throws {
        let (pipe, state, _, _, llm, _, _) = makePipeline()
        llm.nextResult = .failure(LLMError.missingAPIKey)
        await startAndFinalize(pipe, state: state)
        if case .error(let category, let msg) = state.status {
            #expect(category == .pipeline)
            #expect(msg.contains("Settings"))
        } else {
            Issue.record("expected .error")
        }
    }

    @Test func paste_failure_setsErrorState() async throws {
        struct StubError: Error {}
        let (pipe, state, _, _, _, _, injector) = makePipeline()
        injector.nextError = StubError()
        await startAndFinalize(pipe, state: state)
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

    @Test func startRecording_skipsWhenAlreadyRecording() {
        let (pipe, state, capture, _, _, _, _) = makePipeline()
        state.status = .recording
        pipe.startRecording()
        #expect(capture.startCallCount == 0)
    }

    @Test func startRecording_skipsWhenThinking() {
        // Reentrancy guard: a second chord (or stray Debug-button call) must
        // not start a fresh recording while the prior pipeline is still
        // awaiting transcribe/llm/paste.
        let (pipe, state, capture, _, _, _, _) = makePipeline()
        state.status = .thinking
        pipe.startRecording()
        #expect(capture.startCallCount == 0)
    }

    @Test func finalizeRecording_noopWhenNotRecording() async {
        let (pipe, state, capture, transcriber, llm, _, _) = makePipeline()
        state.status = .idle
        await pipe.finalizeRecording()
        #expect(capture.stopCallCount == 0)
        #expect(transcriber.transcribeCallCount == 0)
        #expect(llm.calls.isEmpty)
    }

    @Test func finalizeRecording_noopWhenAlreadyThinking() async {
        // Ensure a second finalize call (e.g. from `tapDisabled` arriving after
        // chord-release already triggered the first finalize) doesn't tear
        // down a pipeline mid-flight.
        let (pipe, state, capture, transcriber, _, _, _) = makePipeline()
        state.status = .thinking
        await pipe.finalizeRecording()
        #expect(capture.stopCallCount == 0)
        #expect(transcriber.transcribeCallCount == 0)
    }

    @Test func startRecording_afterPipelineError_proceeds() {
        // Pipeline errors (paste failed, transcription failed, etc.) are
        // user-recoverable by retrying. Pressing the chord again should
        // start a new recording.
        let (pipe, state, capture, _, _, _, _) = makePipeline()
        state.status = .error(category: .pipeline, message: "Paste failed.")
        pipe.startRecording()
        #expect(capture.startCallCount == 1)
        #expect(state.status == .recording)
    }

    @Test func startRecording_afterPermissionsError_isSticky() {
        // Permissions errors must NOT be cleared by a chord press: the tap
        // is uninstalled, the chord literally won't work until the user
        // re-grants permissions, and silently transitioning to .recording
        // would mask that.
        let (pipe, state, capture, _, _, _, _) = makePipeline()
        let stickyMessage = "Accessibility revoked. Re-grant in System Settings."
        state.status = .error(category: .permissions, message: stickyMessage)
        pipe.startRecording()
        #expect(capture.startCallCount == 0)
        #expect(state.status == .error(category: .permissions, message: stickyMessage))
    }
}
