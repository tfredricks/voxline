import Testing
import Foundation
@testable import voxline

@Suite @MainActor struct CapturePipelineTests {

    final class FakeCapture: AudioCapturing {
        var onLevel: ((Float) -> Void)?
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
        /// Invoked during `cleanup`, after the call is recorded and before the
        /// result is returned — lets tests simulate MainActor reentrancy.
        var onCleanup: (() -> Void)? = nil
        /// When true, `cleanup` suspends until `releaseCleanup()`.
        var holdCleanup = false
        let cleanupGate = TestGate()
        func releaseCleanup() { cleanupGate.open() }
        func cleanup(transcript: String, mode: Mode, context: CapturedContext) async throws -> String {
            calls.append((transcript, mode, context))
            onCleanup?()
            if holdCleanup { await cleanupGate.wait() }
            return try nextResult.get()
        }

        /// Answered in order; once empty, every command replaces the
        /// selection with "transformed".
        var commandResults: [Result<CommandResult, Error>] = []
        private(set) var commandRequests: [CommandRequest] = []
        /// Invoked off the main actor as each command is recorded.
        var onCommand: (@Sendable () -> Void)?
        /// When true, `command` suspends until `releaseCommand()`.
        var holdCommand = false
        let commandGate = TestGate()
        func releaseCommand() { commandGate.open() }
        func command(_ request: CommandRequest) async throws -> CommandResult {
            commandRequests.append(request)
            onCommand?()
            if holdCommand { await commandGate.wait() }
            let next = commandResults.isEmpty
                ? .success(CommandResult(action: .replaceSelection, text: "transformed"))
                : commandResults.removeFirst()
            return try next.get()
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

    final class FakeSelectionSnapshot: SelectionSnapshotting, @unchecked Sendable {
        var selection: String?
        private(set) var readCount = 0
        func readSelection() async -> String? { readCount += 1; return selection }
    }

    private func startAndFinalize(_ pipe: CapturePipeline, state: AppState) async {
        pipe.startRecording()
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
    ) -> (pipe: CapturePipeline, state: AppState, capture: FakeCapture, engine: FakeTranscriptionEngine, llm: FakeLLM, frontmost: FakeFrontmost, inspector: FakeFieldInspector, inserter: FakeTextInserter, history: DictationHistoryStore) {
        let state = AppState()
        let capture = FakeCapture()
        let engine = FakeTranscriptionEngine()
        let llm = FakeLLM()
        let front = FakeFrontmost(); front.bundleID = frontmostBundleID
        let inspector = FakeFieldInspector(); inspector.field = focusedField
        let inserter = FakeTextInserter()
        let router = ModeRouter(modes: modes)
        let suiteName = "voxline-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let history = DictationHistoryStore(defaults: defaults)
        let pipe = CapturePipeline(
            state: state, capture: capture, engines: FakeEngineProvider(engine),
            llm: llm, modes: router, frontmost: front,
            fieldInspector: inspector, inserter: inserter,
            historyStore: history, contextCapture: FakeContextCapture(),
            selectionSnapshot: FakeSelectionSnapshot(),
            llmModelID: { "test-model" },
            vocabulary: { [] },
            skipShortUtterances: { false },
            chords: { .default }
        )
        return (pipe, state, capture, engine, llm, front, inspector, inserter, history)
    }

    private func makePipelineWithContext(
        frontmostBundleID: String? = "com.tinyspeck.slackmacgap",
        focusedField: FocusedField? = nil
    ) -> (pipe: CapturePipeline, state: AppState, capture: FakeCapture, engine: FakeTranscriptionEngine, llm: FakeLLM, frontmost: FakeFrontmost, inspector: FakeFieldInspector, inserter: FakeTextInserter, history: DictationHistoryStore, contextCapture: FakeContextCapture) {
        let (_, state, capture, engine, llm, front, inspector, inserter, history) = makePipeline(
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
            fieldInspector: inspector, inserter: inserter,
            historyStore: history, contextCapture: ctx,
            selectionSnapshot: FakeSelectionSnapshot(),
            llmModelID: { "test-model" },
            vocabulary: { [] },
            skipShortUtterances: { false },
            chords: { .default }
        )
        return (pipe, state, capture, engine, llm, front, inspector, inserter, history, ctx)
    }

    @Test func startRecording_setsStateAndStartsCapture() {
        let (pipe, state, capture, _, _, _, _, _, _) = makePipeline()
        pipe.startRecording()
        #expect(state.status == .recording)
        #expect(state.recordingStartedAt != nil)
        #expect(capture.startCallCount == 1)
    }

    @Test func onRecordingStarted_firesOnceTheFirstAudioArrives() async {
        let (pipe, _, _, _, _, _, _, _, _) = makePipeline()
        let log = Log()
        pipe.onRecordingStarted = { log.events.append("started") }
        pipe.startRecording()
        #expect(log.events.isEmpty, "the cue must wait for audio, not fire on the keypress")
        await drainMainActor()
        #expect(log.events == ["started"])
    }

    @Test func onRecordingStarted_waitsForAudioFromTheTap() async {
        let (pipe, _, capture, _, _, _, _, _, _) = makePipeline()
        capture.pendingSamples = []
        let log = Log()
        pipe.onRecordingStarted = { log.events.append("started") }
        pipe.startRecording()
        await drainMainActor()
        #expect(log.events.isEmpty)
        capture.onSamples?([0.1, 0.2])
        capture.onSamples?([0.3])
        await drainMainActor()
        #expect(log.events == ["started"], "fires once, on the first chunk only")
    }

    @Test func onRecordingStarted_doesNotFireWhenCaptureFails() async {
        let (pipe, _, capture, _, _, _, _, _, _) = makePipeline()
        struct Boom: Error {}
        capture.startError = Boom()
        let log = Log()
        pipe.onRecordingStarted = { log.events.append("started") }
        pipe.startRecording()
        await drainMainActor()
        #expect(log.events.isEmpty)
    }

    @Test func onRecordingStarted_doesNotFireForARecordingAlreadyCancelled() async {
        let (pipe, _, capture, _, _, _, _, _, _) = makePipeline()
        capture.pendingSamples = []
        let log = Log()
        pipe.onRecordingStarted = { log.events.append("started") }
        pipe.startRecording()
        let tap = capture.onSamples
        pipe.cancel()
        tap?([0.1])
        await drainMainActor()
        #expect(log.events.isEmpty, "audio from a cancelled recording must not play the start cue")
    }

    final class Log {
        var events: [String] = []
    }

    /// Lets main-actor tasks queued by the code under test run.
    private func drainMainActor() async {
        for _ in 0..<5 { await Task.yield() }
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
        let (pipe, state, _, engine, llm, _, _, inserter, _) = makePipeline()
        let session = willTranscribe(engine, .success("uh hello there"))
        llm.nextResult = .success("Hello there.")
        await startAndFinalize(pipe, state: state)

        #expect(session.finishCount == 1)
        #expect(llm.calls.count == 1)
        #expect(llm.calls[0].transcript == "uh hello there")
        #expect(llm.calls[0].mode.bundleID == "com.tinyspeck.slackmacgap")
        #expect(inserter.calls.map(\.text) == ["Hello there."])
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
        let (pipe, state, _, engine, llm, _, _, inserter, _) = makePipeline()
        willTranscribe(engine, .failure(StubError()))
        await startAndFinalize(pipe, state: state)
        if case .error = state.status { } else { Issue.record("expected .error") }
        #expect(llm.calls.isEmpty)
        #expect(inserter.calls.isEmpty)
    }

    @Test func empty_transcript_skips_llm_and_paste() async throws {
        let (pipe, state, _, engine, llm, _, _, inserter, _) = makePipeline()
        willTranscribe(engine, .success(""))
        await startAndFinalize(pipe, state: state)
        #expect(llm.calls.isEmpty)
        #expect(inserter.calls.isEmpty)
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
        let (pipe, state, _, _, _, _, _, inserter, _) = makePipeline()
        inserter.outcomes = [.failed(.allStrategiesFailed(["Typing produced no change"]))]
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
        let (pipe, state, _, _, llm, _, _, inserter, history) = makePipeline()
        llm.nextResult = .success("Hello there.")
        inserter.outcomes = [.failed(.allStrategiesFailed(["Typing produced no change"]))]
        await startAndFinalize(pipe, state: state)
        if case .error = state.status { } else { Issue.record("expected .error") }
        #expect(history.items.count == 1)
        #expect(history.items[0].cleanedText == "Hello there.")
    }

    @Test func finalize_nonEditableFocusedField_copiesInsteadOfPasting() async throws {
        let (pipe, state, _, _, _, _, _, inserter, history) = makePipeline(
            focusedField: FocusedField(role: "AXButton", subrole: nil)
        )
        let copied = LockedBox<[String]>([])
        pipe.transcriptFallback = { text in copied.mutate { $0.append(text) } }

        await startAndFinalize(pipe, state: state)

        #expect(inserter.calls.isEmpty)
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
        let (pipe, state, _, _, llm, _, _, inserter, _) = makePipeline()
        llm.nextResult = .failure(LLMError.rateLimited)
        var fallbackTranscripts: [String] = []
        pipe.transcriptFallback = { fallbackTranscripts.append($0) }

        await startAndFinalize(pipe, state: state)

        #expect(fallbackTranscripts == ["hello world"], "the raw transcript must survive the cleanup failure")
        #expect(inserter.calls.isEmpty, "nothing gets pasted on failure")
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

    // MARK: - Selection

    @Test func dictation_never_reads_the_selection_or_the_edit_context() async {
        let state = AppState()
        let engine = FakeTranscriptionEngine()
        let llm = FakeLLM()
        let front = FakeFrontmost(); front.bundleID = "com.tinyspeck.slackmacgap"
        let inserter = FakeTextInserter()
        let snap = FakeSelectionSnapshot(); snap.selection = "user had something selected"
        let reader = FakeEditContextReader.needingCopy()
        let name = "voxline-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let pipe = CapturePipeline(
            state: state, capture: FakeCapture(), engines: FakeEngineProvider(engine),
            llm: llm, modes: ModeRouter(modes: [
                Mode(bundleID: "*", displayName: "Default", prompt: "default-prompt", model: nil, temperature: nil, category: .general)
            ]), frontmost: front,
            fieldInspector: FakeFieldInspector(), inserter: inserter,
            historyStore: DictationHistoryStore(defaults: defaults), contextCapture: FakeContextCapture(),
            selectionSnapshot: snap,
            editContextReader: reader,
            llmModelID: { "test-model" },
            commandModelID: { nil },
            vocabulary: { [] },
            skipShortUtterances: { false },
            chords: { .default },
            releaseGate: .released
        )

        pipe.startRecording(kind: .dictation)
        await pipe.finalizeRecording()

        #expect(snap.readCount == 0)
        #expect(reader.readCount == 0)
        #expect(inserter.clipboardRestoreWaits == 0)
        #expect(llm.commandRequests.isEmpty)
        #expect(llm.calls.count == 1)
        #expect(inserter.calls.map(\.text) == ["cleaned"])
    }

    @Test func recordingKind_is_dictation_while_recording_and_nil_after() async {
        let (pipe, state, _, _, _, _, _, _, _) = makePipeline()
        #expect(state.recordingKind == nil)
        pipe.startRecording()
        #expect(state.recordingKind == .dictation)
        await pipe.finalizeRecording()
        #expect(state.status == .idle)
        #expect(state.recordingKind == nil)
    }

    @Test func recordingKind_clears_on_the_error_path() async {
        let (pipe, state, _, _, llm, _, _, _, _) = makePipeline()
        llm.nextResult = .failure(LLMError.rateLimited)
        pipe.transcriptFallback = { _ in }
        pipe.startRecording(kind: .dictation)
        await pipe.finalizeRecording()
        if case .error = state.status {} else { Issue.record("expected .error, got \(state.status)") }
        #expect(state.recordingKind == nil)
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

    // MARK: - Insert outcomes

    @Test func dictation_inserts_at_live_selection_with_dictation_families() async throws {
        let (pipe, state, _, _, _, _, _, inserter, _) = makePipeline()
        await startAndFinalize(pipe, state: state)

        let call = try #require(inserter.calls.first)
        #expect(inserter.calls.count == 1)
        #expect(call.text == "cleaned")
        #expect(call.target == .liveSelection)
        #expect(call.expected == nil)
        #expect(call.bundleID == "com.tinyspeck.slackmacgap")
        #expect(call.trigger == ChordSet.default.dictation.families)
    }

    @Test func dictation_into_a_terminal_still_inserts_at_the_prompt() async throws {
        let (pipe, state, _, _, _, _, _, inserter, _) = makePipeline(frontmostBundleID: "com.apple.Terminal")
        inserter.outcomes = [.inserted(.paste, verified: true)]
        let copied = LockedBox<[String]>([])
        pipe.transcriptFallback = { text in copied.mutate { $0.append(text) } }

        await startAndFinalize(pipe, state: state)

        let call = try #require(inserter.calls.first)
        #expect(inserter.calls.count == 1)
        #expect(call.text == "cleaned")
        #expect(call.target == .liveSelection)
        #expect(call.bundleID == "com.apple.Terminal")
        #expect(copied.read().isEmpty)
        #expect(state.toastMessage == nil)
        #expect(state.status == .idle)
        #expect(try #require(pipe.metrics.items.first).insertStrategy == .paste)
    }

    @Test(arguments: [NotInsertedReason.fieldChanged, .focusMoved, .cannotTarget, .outcomeUnknown])
    func not_inserted_copies_with_the_paste_hint(reason: NotInsertedReason) async throws {
        let (pipe, state, _, _, _, _, _, inserter, history) = makePipeline()
        inserter.outcomes = [.notInserted(reason)]
        let copied = LockedBox<[String]>([])
        pipe.transcriptFallback = { text in copied.mutate { $0.append(text) } }

        await startAndFinalize(pipe, state: state)

        #expect(copied.read() == ["cleaned"])
        #expect(state.toastMessage == "Couldn't insert — copied, ⌘V to paste")
        #expect(state.status == .idle)
        #expect(history.items.first?.cleanedText == "cleaned")
        let row = try #require(pipe.metrics.items.first)
        #expect(row.insertStrategy == .copy)
        #expect(row.insertMs == 0)
        #expect(row.editAction == nil)
    }

    @Test func not_responding_copies_and_says_so() async throws {
        let (pipe, state, _, _, _, _, _, inserter, _) = makePipeline()
        inserter.outcomes = [.notInserted(.notResponding)]
        let copied = LockedBox<[String]>([])
        pipe.transcriptFallback = { text in copied.mutate { $0.append(text) } }

        await startAndFinalize(pipe, state: state)

        #expect(copied.read() == ["cleaned"])
        #expect(state.toastMessage == "Field isn't responding — copied")
        #expect(state.status == .idle)
        #expect(try #require(pipe.metrics.items.first).insertStrategy == .copy)
    }

    @Test func secure_field_is_todays_error() async {
        let (pipe, state, _, _, _, _, _, inserter, _) = makePipeline()
        inserter.outcomes = [.notInserted(.secure)]
        let copied = LockedBox<[String]>([])
        pipe.transcriptFallback = { text in copied.mutate { $0.append(text) } }

        await startAndFinalize(pipe, state: state)

        guard case .error(let message) = state.status else {
            Issue.record("expected .error, got \(state.status)"); return
        }
        #expect(message == TextInsertionError.secureFieldUnsupported.errorDescription)
        #expect(message.contains("secure text field"))
        #expect(copied.read().isEmpty)
        #expect(pipe.metrics.items.isEmpty)
    }

    @Test func accessibility_not_granted_is_a_permissions_error() async {
        let (pipe, state, _, _, _, _, _, inserter, _) = makePipeline()
        inserter.outcomes = [.failed(.accessibilityNotGranted)]

        await startAndFinalize(pipe, state: state)

        #expect(state.status == .permissionsError(TextInsertionError.accessibilityNotGranted.errorDescription!))
        #expect(pipe.metrics.items.isEmpty)
    }

    @Test func paste_verification_failure_is_a_plain_error() async {
        let (pipe, state, _, _, _, _, _, inserter, _) = makePipeline()
        inserter.outcomes = [.failed(.pasteVerificationFailed)]
        let copied = LockedBox<[String]>([])
        pipe.transcriptFallback = { text in copied.mutate { $0.append(text) } }

        await startAndFinalize(pipe, state: state)

        #expect(state.status == .error(TextInsertionError.pasteVerificationFailed.errorDescription!))
        #expect(copied.read().isEmpty)
        #expect(pipe.metrics.items.isEmpty)
        #expect(state.retryTranscript == "hello world")
    }

    @Test func inserted_records_the_strategy() async throws {
        let (pipe, state, _, _, _, _, _, inserter, _) = makePipeline()
        inserter.outcomes = [.inserted(.paste, verified: false)]
        await startAndFinalize(pipe, state: state)
        let row = try #require(pipe.metrics.items.first)
        #expect(row.insertStrategy == .paste)
        #expect(row.editAction == nil)
        #expect(state.toastMessage == nil)
        #expect(state.status == .idle)
    }

    @Test func inserted_through_accessibility_records_ax() async throws {
        let (pipe, state, _, _, _, _, _, _, _) = makePipeline()
        await startAndFinalize(pipe, state: state)
        #expect(try #require(pipe.metrics.items.first).insertStrategy == .ax)
    }

    @Test func no_text_field_records_copy() async throws {
        let (pipe, state, _, _, _, _, _, _, _) = makePipeline(focusedField: FocusedField(role: "AXButton", subrole: nil))
        pipe.transcriptFallback = { _ in }
        await startAndFinalize(pipe, state: state)
        #expect(try #require(pipe.metrics.items.first).insertStrategy == .copy)
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

/// Holds callers in `wait()` until `open()`; stays open afterwards.
/// `waiting` counts callers currently held.
final class TestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var waiting: Int { lock.withLock { waiters.count } }

    func wait() async {
        await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
            let resumeNow = lock.withLock { () -> Bool in
                if isOpen { return true }
                waiters.append(k)
                return false
            }
            if resumeNow { k.resume() }
        }
    }

    func open() {
        let held = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            isOpen = true
            defer { waiters.removeAll() }
            return waiters
        }
        held.forEach { $0.resume() }
    }
}
