import Testing
import Foundation
@testable import voxline

@Suite @MainActor struct CapturePipelineTests {

    final class FakeCapture: AudioCapturing {
        var onLevel: ((Float) -> Void)?
        var onTapCallback: ((Int) -> Void)?
        var startCallCount = 0
        var stopCallCount = 0
        var prewarmCallCount = 0
        var stopPrewarmCallCount = 0
        var pendingSamples: [Float] = [0.1, 0.2, 0.3]
        var startError: Error?
        func prewarm() { prewarmCallCount += 1 }
        func stopPrewarm() { stopPrewarmCallCount += 1 }
        func start() throws {
            startCallCount += 1
            if let startError { throw startError }
        }
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
        var calls: [(transcript: String, mode: Mode, context: CapturedContext)] = []
        func cleanup(transcript: String, mode: Mode, context: CapturedContext) async throws -> String {
            calls.append((transcript, mode, context))
            return try nextResult.get()
        }
    }

    final class FakeFrontmost: FrontmostAppProviding, @unchecked Sendable {
        var bundleID: String?
        func frontmostBundleID() -> String? { bundleID }
    }

    final class FakeFieldInspector: FocusedFieldInspecting, @unchecked Sendable {
        var field: FocusedField?
        func inspect() -> FocusedField? { field }
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
        state.lastPeakLevel = 0.5
        await pipe.finalizeRecording()
    }

    private func makePipeline(
        frontmostBundleID: String? = "com.tinyspeck.slackmacgap",
        focusedField: FocusedField? = nil,
        modes: [Mode] = [
            Mode(bundleID: "com.tinyspeck.slackmacgap", displayName: "Slack", prompt: "slack-prompt", model: nil, temperature: nil, category: .chat),
            Mode(bundleID: "*", displayName: "Default", prompt: "default-prompt", model: nil, temperature: nil, category: .general)
        ]
    ) -> (pipe: CapturePipeline, state: AppState, capture: FakeCapture, transcriber: FakeTranscriber, llm: FakeLLM, frontmost: FakeFrontmost, inspector: FakeFieldInspector, injector: FakeInjector, history: DictationHistoryStore) {
        let state = AppState()
        let capture = FakeCapture()
        let transcriber = FakeTranscriber()
        let llm = FakeLLM()
        let front = FakeFrontmost(); front.bundleID = frontmostBundleID
        let inspector = FakeFieldInspector(); inspector.field = focusedField
        let injector = FakeInjector()
        let router = ModeRouter(modes: modes)
        let suiteName = "voxline-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let history = DictationHistoryStore(defaults: defaults)
        let pipe = CapturePipeline(
            state: state, capture: capture, transcriber: transcriber,
            llm: llm, modes: router, frontmost: front,
            fieldInspector: inspector, injector: injector,
            historyStore: history, contextCapture: FakeContextCapture()
        )
        return (pipe, state, capture, transcriber, llm, front, inspector, injector, history)
    }

    private func makePipelineWithContext(
        frontmostBundleID: String? = "com.tinyspeck.slackmacgap",
        focusedField: FocusedField? = nil
    ) -> (pipe: CapturePipeline, state: AppState, capture: FakeCapture, transcriber: FakeTranscriber, llm: FakeLLM, frontmost: FakeFrontmost, inspector: FakeFieldInspector, injector: FakeInjector, history: DictationHistoryStore, contextCapture: FakeContextCapture) {
        let (_, state, capture, transcriber, llm, front, inspector, injector, history) = makePipeline(
            frontmostBundleID: frontmostBundleID, focusedField: focusedField
        )
        // Re-build the pipeline with all the same deps, plus a FakeContextCapture.
        let ctx = FakeContextCapture()
        let router = ModeRouter(modes: [
            Mode(bundleID: "com.tinyspeck.slackmacgap", displayName: "Slack", prompt: "slack-prompt", model: nil, temperature: nil, category: .chat),
            Mode(bundleID: "*", displayName: "Default", prompt: "default-prompt", model: nil, temperature: nil, category: .general)
        ])
        let pipe = CapturePipeline(
            state: state, capture: capture, transcriber: transcriber,
            llm: llm, modes: router, frontmost: front,
            fieldInspector: inspector, injector: injector,
            historyStore: history, contextCapture: ctx
        )
        return (pipe, state, capture, transcriber, llm, front, inspector, injector, history, ctx)
    }

    @Test func startRecording_setsStateAndStartsCapture() {
        let (pipe, state, capture, _, _, _, _, _, _) = makePipeline()
        pipe.startRecording()
        #expect(state.status == .recording)
        #expect(state.recordingStartedAt != nil)
        #expect(capture.startCallCount == 1)
    }

    @Test func startRecording_whenCaptureStartThrows_stopsAnyPrewarm() {
        let (pipe, state, capture, _, _, _, _, _, _) = makePipeline()
        struct Boom: Error {}
        capture.startError = Boom()
        pipe.startRecording()
        #expect(capture.stopPrewarmCallCount == 1, "a failed start must not strand a prewarmed engine")
        if case .error = state.status {} else { Issue.record("expected .error, got \(state.status)") }
    }

    @Test func finalizeRecording_routesViaModeAndCallsLLMAndPastes() async throws {
        let (pipe, state, _, transcriber, llm, _, _, injector, _) = makePipeline()
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
        let (pipe, state, _, _, llm, _, _, _, _) = makePipeline(frontmostBundleID: "com.unknown.app")
        await startAndFinalize(pipe, state: state)
        #expect(llm.calls[0].mode.bundleID == "*")
    }

    @Test func focused_field_kind_picks_field_specific_mode() async throws {
        // Slack + search-field should beat the catch-all Slack mode.
        let modes: [Mode] = [
            Mode(bundleID: "com.tinyspeck.slackmacgap", displayName: "Slack",
                 prompt: "slack-prompt", model: nil, temperature: nil, fieldKind: nil),
            Mode(bundleID: "com.tinyspeck.slackmacgap", displayName: "Slack search",
                 prompt: "slack-search-prompt", model: nil, temperature: nil, fieldKind: .search),
            Mode(bundleID: "*", displayName: "Default", prompt: "default-prompt",
                 model: nil, temperature: nil, fieldKind: nil)
        ]
        let (pipe, state, _, _, llm, _, _, _, _) = makePipeline(
            focusedField: FocusedField(role: "AXTextField", subrole: "AXSearchField"),
            modes: modes
        )
        await startAndFinalize(pipe, state: state)
        #expect(llm.calls[0].mode.prompt == "slack-search-prompt")
    }

    @Test func transcriptionFailure_setsErrorStateNoLLMNoPaste() async throws {
        struct StubError: Error {}
        let (pipe, state, _, transcriber, llm, _, _, injector, _) = makePipeline()
        transcriber.nextResult = .failure(StubError())
        await startAndFinalize(pipe, state: state)
        if case .error = state.status { } else { Issue.record("expected .error") }
        #expect(llm.calls.isEmpty)
        #expect(injector.injected.isEmpty)
    }

    @Test func empty_transcript_skips_llm_and_paste() async throws {
        let (pipe, state, _, transcriber, llm, _, _, injector, _) = makePipeline()
        transcriber.nextResult = .success("")
        await startAndFinalize(pipe, state: state)
        #expect(llm.calls.isEmpty)
        #expect(injector.injected.isEmpty)
        #expect(state.status == .idle)
    }

    @Test func llm_missingAPIKey_surfacesActionableErrorMessage() async throws {
        let (pipe, state, _, _, llm, _, _, _, _) = makePipeline()
        llm.nextResult = .failure(LLMError.missingAPIKey)
        pipe.transcriptFallback = { _ in } // avoid touching the real pasteboard in tests
        await startAndFinalize(pipe, state: state)
        if case .error(let msg) = state.status {
            #expect(msg.contains("Settings"))
        } else {
            Issue.record("expected .error")
        }
    }

    @Test func paste_failure_setsErrorState() async throws {
        struct StubError: Error {}
        let (pipe, state, _, _, _, _, _, injector, _) = makePipeline()
        injector.nextError = StubError()
        await startAndFinalize(pipe, state: state)
        if case .error = state.status { } else { Issue.record("expected .error") }
    }

    @Test func startRecording_skipsWhenDownloadingModel() {
        let (pipe, state, capture, _, _, _, _, _, _) = makePipeline()
        state.status = .downloadingModel(progress: 0.3)
        pipe.startRecording()
        #expect(capture.startCallCount == 0)
    }

    @Test func startRecording_skipsWhenPreparingModel() {
        let (pipe, state, capture, _, _, _, _, _, _) = makePipeline()
        state.status = .preparingModel
        pipe.startRecording()
        #expect(capture.startCallCount == 0)
    }

    @Test func startRecording_skipsWhenAlreadyRecording() {
        let (pipe, state, capture, _, _, _, _, _, _) = makePipeline()
        state.status = .recording
        pipe.startRecording()
        #expect(capture.startCallCount == 0)
    }

    @Test func startRecording_skipsWhenThinking() {
        // Reentrancy guard: a second chord (or stray Debug-button call) must
        // not start a fresh recording while the prior pipeline is still
        // awaiting transcribe/llm/paste.
        let (pipe, state, capture, _, _, _, _, _, _) = makePipeline()
        state.status = .thinking
        pipe.startRecording()
        #expect(capture.startCallCount == 0)
    }

    @Test func finalizeRecording_noopWhenNotRecording() async {
        let (pipe, state, capture, transcriber, llm, _, _, _, _) = makePipeline()
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
        let (pipe, state, capture, transcriber, _, _, _, _, _) = makePipeline()
        state.status = .thinking
        await pipe.finalizeRecording()
        #expect(capture.stopCallCount == 0)
        #expect(transcriber.transcribeCallCount == 0)
    }

    @Test func startRecording_afterPipelineError_proceeds() {
        // Pipeline errors (paste failed, transcription failed, etc.) are
        // user-recoverable by retrying. Pressing the chord again should
        // start a new recording.
        let (pipe, state, capture, _, _, _, _, _, _) = makePipeline()
        state.status = .error("Paste failed.")
        pipe.startRecording()
        #expect(capture.startCallCount == 1)
        #expect(state.status == .recording)
    }

    @Test func finalizeRecording_setsLastRecordingDurationFromSampleCount() async {
        // lastRecordingDuration drives the recording-pill UI's duration row.
        // Three samples / 16 kHz ≈ 0.0001875s — assert the formula, not a literal.
        let (pipe, state, _, _, _, _, _, _, _) = makePipeline()
        await startAndFinalize(pipe, state: state)
        guard let duration = state.lastRecordingDuration else {
            Issue.record("expected non-nil lastRecordingDuration"); return
        }
        // FakeCapture.pendingSamples has 3 samples by default.
        #expect(duration == 3.0 / 16_000.0)
    }

    @Test func finalizeRecording_setsDurationEvenOnSilentMicAbort() async {
        // Silent-capture detector aborts the pipeline before transcribe, but
        // we set duration before the detector runs — so a 0-duration zero-peak
        // run still has a duration recorded for the panel to show.
        let (pipe, state, capture, _, _, _, _, _, _) = makePipeline()
        capture.pendingSamples = [Float](repeating: 0, count: 16_000)
        pipe.startRecording()
        // Don't simulate onLevel — peak stays at 0, triggers silent-mic error.
        state.lastPeakLevel = 0
        await pipe.finalizeRecording()
        if case .error = state.status { } else { Issue.record("expected silent-mic error") }
        #expect(state.lastRecordingDuration == 1.0)
    }

    @Test func startRecording_afterPermissionsError_isSticky() {
        // Permissions errors must NOT be cleared by a chord press: the tap
        // is uninstalled, the chord literally won't work until the user
        // re-grants permissions, and silently transitioning to .recording
        // would mask that.
        let (pipe, state, capture, _, _, _, _, _, _) = makePipeline()
        let stickyMessage = "Accessibility revoked. Re-grant in System Settings."
        state.status = .permissionsError(stickyMessage)
        pipe.startRecording()
        #expect(capture.startCallCount == 0)
        #expect(state.status == .permissionsError(stickyMessage))
    }

    @Test func finalizeRecording_recordsCleanedTextInHistory() async throws {
        let (pipe, state, _, transcriber, llm, _, _, _, history, ctx) = makePipelineWithContext()
        transcriber.nextResult = .success("uh hello there")
        llm.nextResult = .success("Hello there.")
        var captured = CapturedContext.empty
        captured.appName = "Slack"
        captured.bundleID = "com.tinyspeck.slackmacgap"
        ctx.nextContext = captured

        await startAndFinalize(pipe, state: state)

        #expect(history.items.count == 1)
        let item = try #require(history.items.first)
        #expect(item.cleanedText == "Hello there.")
        #expect(item.modeCategoryName == "Chat")
        #expect(item.appName == "Slack")
        #expect(item.appBundleID == "com.tinyspeck.slackmacgap")
    }

    @Test func empty_transcript_doesNotRecordInHistory() async throws {
        let (pipe, state, _, transcriber, _, _, _, _, history) = makePipeline()
        transcriber.nextResult = .success("")
        await startAndFinalize(pipe, state: state)
        #expect(history.items.isEmpty)
    }

    @Test func transcriptionFailure_doesNotRecordInHistory() async throws {
        struct StubError: Error {}
        let (pipe, state, _, transcriber, _, _, _, _, history) = makePipeline()
        transcriber.nextResult = .failure(StubError())
        await startAndFinalize(pipe, state: state)
        #expect(history.items.isEmpty)
    }

    @Test func llmFailure_doesNotRecordInHistory() async throws {
        let (pipe, state, _, _, llm, _, _, _, history) = makePipeline()
        llm.nextResult = .failure(LLMError.missingAPIKey)
        pipe.transcriptFallback = { _ in } // avoid touching the real pasteboard in tests
        await startAndFinalize(pipe, state: state)
        #expect(history.items.isEmpty)
    }

    @Test func paste_failure_stillRecordsInHistory() async throws {
        struct StubError: Error {}
        let (pipe, state, _, _, llm, _, _, injector, history) = makePipeline()
        llm.nextResult = .success("Hello there.")
        injector.nextError = StubError()
        await startAndFinalize(pipe, state: state)
        if case .error = state.status { } else { Issue.record("expected .error") }
        #expect(history.items.count == 1)
        #expect(history.items[0].cleanedText == "Hello there.")
    }

    @Test func finalize_passes_captured_context_to_llm() async {
        let (pipe, state, _, _, llm, _, _, _, _, ctx) = makePipelineWithContext()
        var captured = CapturedContext.empty
        captured.appName = "Slack"
        captured.bundleID = "com.tinyspeck.slackmacgap"
        ctx.nextContext = captured

        await startAndFinalize(pipe, state: state)

        #expect(llm.calls.count == 1)
        #expect(llm.calls.first?.context.appName == "Slack")
        #expect(llm.calls.first?.context.bundleID == "com.tinyspeck.slackmacgap")
        #expect(ctx.captureCallCount == 1)
    }

    @Test func finalize_with_empty_capture_passes_empty_context() async {
        let (pipe, state, _, _, llm, _, _, _, _, ctx) = makePipelineWithContext()
        ctx.nextContext = .empty

        await startAndFinalize(pipe, state: state)

        #expect(llm.calls.first?.context == CapturedContext.empty)
    }

    // MARK: - Prewarm gating

    @Test func prewarmCapture_forwardsWhenIdle() {
        let (pipe, _, capture, _, _, _, _, _, _) = makePipeline()
        pipe.prewarmCapture()
        #expect(capture.prewarmCallCount == 1)
    }

    @Test func prewarmCapture_forwardsWhenInClearableError() {
        let (pipe, state, capture, _, _, _, _, _, _) = makePipeline()
        state.status = .error("previous dictation failed")
        pipe.prewarmCapture()
        #expect(capture.prewarmCallCount == 1)
    }

    @Test func prewarmCapture_refusedWhileThinking() {
        let (pipe, state, capture, _, _, _, _, _, _) = makePipeline()
        state.status = .thinking
        pipe.prewarmCapture()
        #expect(capture.prewarmCallCount == 0, "prewarm must not light the mic while the pipeline can't record")
    }

    @Test func prewarmCapture_refusedDuringModelDownload() {
        let (pipe, state, capture, _, _, _, _, _, _) = makePipeline()
        state.status = .downloadingModel(progress: 0.5)
        pipe.prewarmCapture()
        #expect(capture.prewarmCallCount == 0)
    }

    @Test func cancelCapturePrewarm_forwardsUnconditionally() {
        let (pipe, _, capture, _, _, _, _, _, _) = makePipeline()
        pipe.cancelCapturePrewarm()
        #expect(capture.stopPrewarmCallCount == 1)
    }

    @Test func startRecording_whenRefused_stopsAnyPrewarm() {
        let (pipe, state, capture, _, _, _, _, _, _) = makePipeline()
        state.status = .thinking
        pipe.startRecording()
        #expect(capture.startCallCount == 0)
        #expect(capture.stopPrewarmCallCount == 1, "a prewarmed engine must not be left running when recording is refused")
    }

    // MARK: - Raw-transcript fallback

    @Test func llmFailure_handsRawTranscriptToFallbackAndSaysSo() async {
        let (pipe, state, _, _, llm, _, _, injector, _) = makePipeline()
        llm.nextResult = .failure(LLMError.rateLimited)
        var fallbackTranscripts: [String] = []
        pipe.transcriptFallback = { fallbackTranscripts.append($0) }

        await startAndFinalize(pipe, state: state)

        #expect(fallbackTranscripts == ["hello world"], "the raw transcript must survive the cleanup failure")
        #expect(injector.injected.isEmpty, "nothing gets pasted on failure")
        if case .error(let message) = state.status {
            #expect(message.contains("clipboard"), "the error must tell the user where their words went")
        } else {
            Issue.record("expected .error status, got \(state.status)")
        }
    }

    @Test func successfulCleanup_doesNotInvokeFallback() async {
        let (pipe, state, _, _, _, _, _, _, _) = makePipeline()
        var fallbackCalls = 0
        pipe.transcriptFallback = { _ in fallbackCalls += 1 }

        await startAndFinalize(pipe, state: state)

        #expect(fallbackCalls == 0)
    }

}

final class FakeContextCapture: ContextCapturing, @unchecked Sendable {
    var nextContext = CapturedContext.empty
    var captureCallCount = 0
    func capture() async -> CapturedContext {
        captureCallCount += 1
        return nextContext
    }
}
