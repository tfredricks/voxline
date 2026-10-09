import Testing
import Foundation
@testable import voxline

@Suite @MainActor struct CapturePipelineTests {

    final class FakeCapture: AudioCapturing {
        var onLevel: ((Float) -> Void)?
        var onTapCallback: ((Int) -> Void)?
        var onSamples: (@Sendable ([Float]) -> Void)?
        var onInterrupted: (() -> Void)?
        var startCallCount = 0
        var stopCallCount = 0
        var prewarmCallCount = 0
        var stopPrewarmCallCount = 0
        /// Delivered through `onSamples` inside `start()`, before any session
        /// opens. 0.5 s by default, over the pipeline's 0.3 s minimum.
        var pendingSamples: [Float] = [Float](repeating: 0.1, count: 8_000)
        var startError: Error?
        func prewarm() { prewarmCallCount += 1 }
        func stopPrewarm() { stopPrewarmCallCount += 1 }
        func start() throws {
            startCallCount += 1
            if let startError { throw startError }
            if !pendingSamples.isEmpty { onSamples?(pendingSamples) }
        }
        func stop() { stopCallCount += 1 }
    }

    final class FakeLLM: LLMServing, @unchecked Sendable {
        var nextResult: Result<String, Error> = .success("cleaned")
        var calls: [(transcript: String, mode: Mode, context: CapturedContext)] = []
        var transformResult: Result<String, Error> = .success("transformed")
        var transformCalls: [(instruction: String, selection: String, mode: Mode)] = []
        /// Invoked during `cleanup`/`transform`, after the call is recorded and
        /// before the result is returned — lets tests simulate MainActor
        /// reentrancy (e.g. the selection changing mid-flight).
        var onCleanup: (() -> Void)? = nil
        func cleanup(transcript: String, mode: Mode, context: CapturedContext) async throws -> String {
            calls.append((transcript, mode, context))
            onCleanup?()
            return try nextResult.get()
        }
        func transform(instruction: String, selection: String, mode: Mode) async throws -> String {
            transformCalls.append((instruction, selection, mode))
            onCleanup?()
            return try transformResult.get()
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

    final class FakeSelectionSnapshot: SelectionSnapshotting, @unchecked Sendable {
        var selection: String?
        private(set) var readCount = 0
        func readSelection() async -> String? { readCount += 1; return selection }
    }

    private func startAndFinalize(_ pipe: CapturePipeline, state: AppState, command: Bool = false) async {
        pipe.startRecording(command: command)
        await pipe.finalizeRecording()
    }

    /// Queues the session the next recording opens, finishing with `result`.
    @discardableResult
    private func willTranscribe(_ engine: FakeTranscriptionEngine, _ result: Result<String, Error>) -> FakeTranscriptionSession {
        let session = FakeTranscriptionSession()
        session.finishResult = result
        engine.nextSessions = [session]
        return session
    }

    private func makePipeline(
        frontmostBundleID: String? = "com.tinyspeck.slackmacgap",
        focusedField: FocusedField? = nil,
        modes: [Mode] = [
            Mode(bundleID: "com.tinyspeck.slackmacgap", displayName: "Slack", prompt: "slack-prompt", model: nil, temperature: nil, category: .chat),
            Mode(bundleID: "*", displayName: "Default", prompt: "default-prompt", model: nil, temperature: nil, category: .general)
        ]
    ) -> (pipe: CapturePipeline, state: AppState, capture: FakeCapture, engine: FakeTranscriptionEngine, llm: FakeLLM, frontmost: FakeFrontmost, inspector: FakeFieldInspector, injector: FakeInjector, history: DictationHistoryStore) {
        let state = AppState()
        let capture = FakeCapture()
        let engine = FakeTranscriptionEngine()
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
            state: state, capture: capture, engines: FakeEngineProvider(engine),
            llm: llm, modes: router, frontmost: front,
            fieldInspector: inspector, injector: injector,
            historyStore: history, contextCapture: FakeContextCapture(),
            selectionSnapshot: FakeSelectionSnapshot(),
            llmModelID: { "test-model" },
            vocabulary: { [] },
            skipShortUtterances: { false }
        )
        return (pipe, state, capture, engine, llm, front, inspector, injector, history)
    }

    private func makePipelineWithContext(
        frontmostBundleID: String? = "com.tinyspeck.slackmacgap",
        focusedField: FocusedField? = nil
    ) -> (pipe: CapturePipeline, state: AppState, capture: FakeCapture, engine: FakeTranscriptionEngine, llm: FakeLLM, frontmost: FakeFrontmost, inspector: FakeFieldInspector, injector: FakeInjector, history: DictationHistoryStore, contextCapture: FakeContextCapture) {
        let (_, state, capture, engine, llm, front, inspector, injector, history) = makePipeline(
            frontmostBundleID: frontmostBundleID, focusedField: focusedField
        )
        // Re-build the pipeline with all the same deps, plus a FakeContextCapture.
        let ctx = FakeContextCapture()
        let router = ModeRouter(modes: [
            Mode(bundleID: "com.tinyspeck.slackmacgap", displayName: "Slack", prompt: "slack-prompt", model: nil, temperature: nil, category: .chat),
            Mode(bundleID: "*", displayName: "Default", prompt: "default-prompt", model: nil, temperature: nil, category: .general)
        ])
        let pipe = CapturePipeline(
            state: state, capture: capture, engines: FakeEngineProvider(engine),
            llm: llm, modes: router, frontmost: front,
            fieldInspector: inspector, injector: injector,
            historyStore: history, contextCapture: ctx,
            selectionSnapshot: FakeSelectionSnapshot(),
            llmModelID: { "test-model" },
            vocabulary: { [] },
            skipShortUtterances: { false }
        )
        return (pipe, state, capture, engine, llm, front, inspector, injector, history, ctx)
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
        let (pipe, state, _, engine, llm, _, _, injector, _) = makePipeline()
        let session = willTranscribe(engine, .success("uh hello there"))
        llm.nextResult = .success("Hello there.")
        await startAndFinalize(pipe, state: state)

        #expect(session.finishCount == 1)
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
        let (pipe, state, _, engine, llm, _, _, injector, _) = makePipeline()
        willTranscribe(engine, .failure(StubError()))
        await startAndFinalize(pipe, state: state)
        if case .error = state.status { } else { Issue.record("expected .error") }
        #expect(llm.calls.isEmpty)
        #expect(injector.injected.isEmpty)
    }

    @Test func empty_transcript_skips_llm_and_paste() async throws {
        let (pipe, state, _, engine, llm, _, _, injector, _) = makePipeline()
        willTranscribe(engine, .success(""))
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
        let (pipe, state, capture, engine, llm, _, _, _, _) = makePipeline()
        state.status = .idle
        await pipe.finalizeRecording()
        #expect(capture.stopCallCount == 0)
        #expect(engine.sessions.isEmpty)
        #expect(llm.calls.isEmpty)
    }

    @Test func finalizeRecording_noopWhenAlreadyThinking() async {
        // Ensure a second finalize call (e.g. from `tapDisabled` arriving after
        // chord-release already triggered the first finalize) doesn't tear
        // down a pipeline mid-flight.
        let (pipe, state, capture, engine, _, _, _, _, _) = makePipeline()
        state.status = .thinking
        await pipe.finalizeRecording()
        #expect(capture.stopCallCount == 0)
        #expect(engine.sessions.isEmpty)
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
        let (pipe, state, capture, _, _, _, _, _, _) = makePipeline()
        capture.pendingSamples = [Float](repeating: 0.1, count: 12_345)
        await startAndFinalize(pipe, state: state)
        guard let duration = state.lastRecordingDuration else {
            Issue.record("expected non-nil lastRecordingDuration"); return
        }
        #expect(duration == 12_345.0 / 16_000.0)
    }

    @Test func finalizeRecording_setsDurationEvenOnSilentMicAbort() async {
        // Silent-capture detector aborts the pipeline before transcribe, but
        // we set duration before the detector runs — so a 0-duration zero-peak
        // run still has a duration recorded for the panel to show.
        let (pipe, state, capture, _, _, _, _, _, _) = makePipeline()
        capture.pendingSamples = [Float](repeating: 0, count: 16_000)
        pipe.startRecording()
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
        let (pipe, state, _, engine, llm, _, _, _, history, ctx) = makePipelineWithContext()
        willTranscribe(engine, .success("uh hello there"))
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
        let (pipe, state, _, engine, _, _, _, _, history) = makePipeline()
        willTranscribe(engine, .success(""))
        await startAndFinalize(pipe, state: state)
        #expect(history.items.isEmpty)
    }

    @Test func transcriptionFailure_doesNotRecordInHistory() async throws {
        struct StubError: Error {}
        let (pipe, state, _, engine, _, _, _, _, history) = makePipeline()
        willTranscribe(engine, .failure(StubError()))
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

    @Test func finalize_nonEditableFocusedField_copiesInsteadOfPasting() async throws {
        let (pipe, state, _, _, _, _, _, injector, history) = makePipeline(
            focusedField: FocusedField(role: "AXButton", subrole: nil)
        )
        let copied = LockedBox<[String]>([])
        pipe.transcriptFallback = { text in copied.mutate { $0.append(text) } }

        await startAndFinalize(pipe, state: state)

        #expect(injector.injected.isEmpty)
        #expect(copied.read() == ["cleaned"])
        #expect(state.toastMessage == "No text field focused — copied")
        #expect(state.status == .idle)
        #expect(history.items.first?.cleanedText == "cleaned")
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

    // MARK: - Selection detection + transform

    private func makeTransformPipeline(
        selection: String,
        focusedField: FocusedField? = nil
    ) -> (CapturePipeline, AppState, FakeLLM, FakeInjector, DictationHistoryStore) {
        let state = AppState()
        let capture = FakeCapture()
        let engine = FakeTranscriptionEngine()
        let llm = FakeLLM()
        let front = FakeFrontmost(); front.bundleID = "com.tinyspeck.slackmacgap"
        let inspector = FakeFieldInspector(); inspector.field = focusedField
        let injector = FakeInjector()
        let snap = FakeSelectionSnapshot(); snap.selection = selection
        let router = ModeRouter(modes: [
            Mode(bundleID: "com.tinyspeck.slackmacgap", displayName: "Slack", prompt: "slack-prompt", model: nil, temperature: nil, category: .chat),
            Mode(bundleID: "*", displayName: "Default", prompt: "default-prompt", model: nil, temperature: nil, category: .general)
        ])
        let name = "voxline-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let history = DictationHistoryStore(defaults: defaults)
        let pipe = CapturePipeline(
            state: state, capture: capture, engines: FakeEngineProvider(engine),
            llm: llm, modes: router, frontmost: front,
            fieldInspector: inspector, injector: injector,
            historyStore: history, contextCapture: FakeContextCapture(),
            selectionSnapshot: snap,
            llmModelID: { "test-model" },
            vocabulary: { [] },
            skipShortUtterances: { false }
        )
        return (pipe, state, llm, injector, history)
    }

    @Test func finalize_withSelection_transformsAndInjectsOverSelection() async {
        let (pipe, state, llm, injector, history) = makeTransformPipeline(selection: "original text")
        pipe.startRecording(command: true); await pipe.finalizeRecording()

        #expect(llm.transformCalls.last?.selection == "original text")
        #expect(llm.transformCalls.last?.instruction == "hello world")   // the spoken command
        #expect(llm.calls.isEmpty)                                       // dictation cleanup NOT called
        #expect(injector.injected.last == "transformed")                 // pasted over the live selection
        #expect(history.items.first?.cleanedText == "transformed")
        if case .idle = state.status {} else { Issue.record("expected .idle after transform") }
    }

    @Test func finalize_withSelection_recordsSpokenCommandAsRawTranscript() async throws {
        let (pipe, _, _, _, history) = makeTransformPipeline(selection: "original text")
        pipe.startRecording(command: true); await pipe.finalizeRecording()

        let item = try #require(history.items.first)
        #expect(item.cleanedText == "transformed")
        #expect(item.rawTranscript == "hello world")
    }

    @Test func finalize_withSelection_recordsCommandMetricsRow() async throws {
        let (pipe, _, _, _, _) = makeTransformPipeline(selection: "original text")
        pipe.startRecording(command: true); await pipe.finalizeRecording()

        let row = try #require(pipe.metrics.items.first)
        #expect(pipe.metrics.items.count == 1)
        #expect(row.kind == .command)
        #expect(row.wordCount == 1)
        #expect(row.modelID == "test-model")
    }

    @Test func finalize_withSelection_nonEditableField_copiesInsteadOfPasting() async throws {
        let (pipe, state, _, injector, history) = makeTransformPipeline(
            selection: "original text", focusedField: FocusedField(role: "AXStaticText", subrole: nil)
        )
        let copied = LockedBox<[String]>([])
        pipe.transcriptFallback = { text in copied.mutate { $0.append(text) } }
        pipe.startRecording(command: true)
        await pipe.finalizeRecording()

        #expect(injector.injected.isEmpty)
        #expect(copied.read() == ["transformed"])
        #expect(state.toastMessage == "Copied — ⌘V to replace")
        #expect(state.status == .idle)
        #expect(history.items.first?.cleanedText == "transformed")
        #expect(pipe.metrics.items.first?.kind == .command)
    }

    @Test func finalize_withSelection_unchangedResult_showsToastNoWrite() async {
        let (pipe, state, llm, injector, history) = makeTransformPipeline(selection: "original text")
        llm.transformResult = .success("original text")   // model declined → returned selection verbatim
        pipe.startRecording(command: true); await pipe.finalizeRecording()

        #expect(injector.injected.isEmpty)
        #expect(history.items.isEmpty)
        #expect(state.toastMessage == "Couldn't apply that")
        if case .idle = state.status {} else { Issue.record("expected .idle") }
    }

    @Test func finalize_withSelection_llmError_setsError() async {
        let (pipe, state, llm, injector, _) = makeTransformPipeline(selection: "original text")
        llm.transformResult = .failure(LLMError.missingAPIKey)
        pipe.startRecording(command: true); await pipe.finalizeRecording()

        #expect(injector.injected.isEmpty)
        if case .error = state.status {} else { Issue.record("expected .error status") }
    }

    @Test func finalize_withSelection_injectFails_fallsBackToClipboard() async {
        let (pipe, state, _, injector, _) = makeTransformPipeline(selection: "original text")
        injector.nextError = TextInsertionError.pasteVerificationFailed
        var fallbackText: String?
        pipe.transcriptFallback = { fallbackText = $0 }   // capture instead of touching NSPasteboard.general
        pipe.startRecording(command: true); await pipe.finalizeRecording()

        #expect(fallbackText == "transformed")
        #expect(state.toastMessage == "Copied — ⌘V to replace")
    }

    @Test func finalize_withEmptySelection_usesDictationPath() async {
        let (pipe, _, llm, injector, _) = makeTransformPipeline(selection: "")
        pipe.startRecording(); await pipe.finalizeRecording()

        #expect(llm.transformCalls.isEmpty)
        #expect(llm.calls.count == 1)                    // dictation cleanup called
        #expect(injector.injected.last == "cleaned")
    }

    @Test func finalize_withSelection_overLimit_refusesWithToast() async {
        let overLimit = String(repeating: "a", count: DefaultSelectionSnapshot.selectionMax + 1)
        let (pipe, state, llm, injector, history) = makeTransformPipeline(selection: overLimit)
        pipe.startRecording(command: true); await pipe.finalizeRecording()

        #expect(llm.transformCalls.isEmpty)
        #expect(injector.injected.isEmpty)
        #expect(history.items.isEmpty)
        #expect(state.toastMessage == "Selection too long to transform")
        if case .idle = state.status {} else { Issue.record("expected .idle after over-limit refusal") }
    }

    @Test func finalize_withSelection_focusMovedDuringLLM_fallsBackToClipboard() async {
        let state = AppState()
        let capture = FakeCapture()
        let engine = FakeTranscriptionEngine()
        let llm = FakeLLM()
        let front = FakeFrontmost(); front.bundleID = "com.tinyspeck.slackmacgap"
        let inspector = FakeFieldInspector()
        let injector = FakeInjector()
        let snap = FakeSelectionSnapshot(); snap.selection = "original text"
        let router = ModeRouter(modes: [
            Mode(bundleID: "com.tinyspeck.slackmacgap", displayName: "Slack", prompt: "slack-prompt", model: nil, temperature: nil, category: .chat),
            Mode(bundleID: "*", displayName: "Default", prompt: "default-prompt", model: nil, temperature: nil, category: .general)
        ])
        let name = "voxline-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let history = DictationHistoryStore(defaults: defaults)
        let pipe = CapturePipeline(
            state: state, capture: capture, engines: FakeEngineProvider(engine),
            llm: llm, modes: router, frontmost: front,
            fieldInspector: inspector, injector: injector,
            historyStore: history, contextCapture: FakeContextCapture(),
            selectionSnapshot: snap,
            llmModelID: { "test-model" },
            vocabulary: { [] },
            skipShortUtterances: { false }
        )
        // Focus/selection moves mid-await: flip the snapshot from inside
        // `transform` (which fires `onCleanup` before returning).
        llm.onCleanup = { snap.selection = "different text" }
        var fallbackText: String?
        pipe.transcriptFallback = { fallbackText = $0 }

        pipe.startRecording(command: true); await pipe.finalizeRecording()

        #expect(injector.injected.isEmpty)          // did NOT paste over the wrong target
        #expect(fallbackText == "transformed")       // result left on clipboard
        #expect(state.toastMessage == "Copied — ⌘V to replace")
        #expect(history.items.isEmpty)               // focus guard is before history.record
        if case .idle = state.status {} else { Issue.record("expected .idle after focus-moved fallback") }
    }

    @Test func finalize_commandMode_emptySelection_showsSelectToast() async {
        let (pipe, state, llm, injector, history) = makeTransformPipeline(selection: "")
        pipe.startRecording(command: true); await pipe.finalizeRecording()

        #expect(llm.transformCalls.isEmpty)      // no transform attempted
        #expect(llm.calls.isEmpty)               // no dictation cleanup either
        #expect(injector.injected.isEmpty)
        #expect(history.items.isEmpty)
        #expect(state.toastMessage == "Select text to transform")
        if case .idle = state.status {} else { Issue.record("expected .idle") }
    }

    @Test func finalize_dictationMode_neverSpawnsSelectionProbe() async {
        let state = AppState()
        let capture = FakeCapture()
        let engine = FakeTranscriptionEngine()
        let llm = FakeLLM()
        let front = FakeFrontmost(); front.bundleID = "com.tinyspeck.slackmacgap"
        let inspector = FakeFieldInspector()
        let injector = FakeInjector()
        let snap = FakeSelectionSnapshot(); snap.selection = "user had something selected"
        let router = ModeRouter(modes: [
            Mode(bundleID: "com.tinyspeck.slackmacgap", displayName: "Slack", prompt: "slack-prompt", model: nil, temperature: nil, category: .chat),
            Mode(bundleID: "*", displayName: "Default", prompt: "default-prompt", model: nil, temperature: nil, category: .general)
        ])
        let name = "voxline-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let history = DictationHistoryStore(defaults: defaults)
        let pipe = CapturePipeline(
            state: state, capture: capture, engines: FakeEngineProvider(engine),
            llm: llm, modes: router, frontmost: front,
            fieldInspector: inspector, injector: injector,
            historyStore: history, contextCapture: FakeContextCapture(),
            selectionSnapshot: snap,
            llmModelID: { "test-model" },
            vocabulary: { [] },
            skipShortUtterances: { false }
        )

        pipe.startRecording(command: false); await pipe.finalizeRecording()

        #expect(snap.readCount == 0)             // THE FIX: dictation never touches the selection
        #expect(llm.transformCalls.isEmpty)
        #expect(llm.calls.count == 1)            // dictation cleanup ran
        #expect(injector.injected.last == "cleaned")
    }

    @Test func startRecording_command_sets_recordingIsCommand_flag() {
        let (pipe, state, _, _, _, _, _, _, _) = makePipeline()
        pipe.startRecording(command: true)
        #expect(state.recordingIsCommand == true)
    }

    @Test func finalizeRecording_recordsRawTranscriptInHistory() async throws {
        let (pipe, state, _, _, _, _, _, _, history) = makePipeline()
        await startAndFinalize(pipe, state: state)
        let item = try #require(history.items.first)
        #expect(item.cleanedText == "cleaned")
        #expect(item.rawTranscript == "hello world")
    }

    @Test func finalize_success_recordsOneMetricsRow() async throws {
        let (pipe, state, _, _, _, _, _, _, _) = makePipeline()
        await startAndFinalize(pipe, state: state)
        let row = try #require(pipe.metrics.items.first)
        #expect(pipe.metrics.items.count == 1)
        #expect(row.kind == .dictation)
        #expect(row.wordCount == 1)
        #expect(row.modelID == "test-model")
        #expect(row.engineID == "fake:engine")
        #expect(row.totalMs >= row.transcribeMs + row.cleanupMs)
    }

    @Test func finalize_llmFailure_recordsNoMetrics() async {
        let (pipe, state, _, _, llm, _, _, _, _) = makePipeline()
        llm.nextResult = .failure(LLMError.rateLimited)
        pipe.transcriptFallback = { _ in }
        await startAndFinalize(pipe, state: state)
        #expect(pipe.metrics.items.isEmpty)
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
