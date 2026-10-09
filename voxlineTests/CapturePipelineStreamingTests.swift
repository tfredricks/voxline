import Testing
import Foundation
@testable import voxline

@Suite @MainActor struct CapturePipelineStreamingTests {

    typealias FakeCapture = CapturePipelineTests.FakeCapture
    typealias FakeSelectionSnapshot = CapturePipelineTests.FakeSelectionSnapshot

    /// Reads and writes are lock-guarded because the start snapshot reads
    /// from a detached task. `reads` lets a test wait until the snapshot ran.
    final class LockedFrontmost: FrontmostAppProviding, @unchecked Sendable {
        private let lock = NSLock()
        private var _bundleID: String?
        private var _reads = 0
        init(_ bundleID: String?) { _bundleID = bundleID }
        var bundleID: String? {
            get { lock.withLock { _bundleID } }
            set { lock.withLock { _bundleID = newValue } }
        }
        var reads: Int { lock.withLock { _reads } }
        func frontmostBundleID() -> String? {
            lock.withLock { _reads += 1; return _bundleID }
        }
    }

    final class LockedFieldInspector: FocusedFieldInspecting, @unchecked Sendable {
        private let lock = NSLock()
        private var _field: FocusedField?
        private var _reads = 0
        init(_ field: FocusedField?) { _field = field }
        var field: FocusedField? {
            get { lock.withLock { _field } }
            set { lock.withLock { _field = newValue } }
        }
        var reads: Int { lock.withLock { _reads } }
        func inspect() -> FocusedField? {
            lock.withLock { _reads += 1; return _field }
        }
    }

    struct Observation: Equatable {
        let isCancellable: Bool
        let phase: PipelinePhase?
    }

    @MainActor
    final class ObservingLLM: LLMServing {
        weak var state: AppState?
        var result: Result<String, Error> = .success("cleaned")
        private(set) var calls: [(transcript: String, mode: Mode)] = []
        private(set) var observed: [Observation] = []
        func cleanup(transcript: String, mode: Mode, context: CapturedContext) async throws -> String {
            calls.append((transcript, mode))
            if let state { observed.append(Observation(isCancellable: state.isCancellable, phase: state.pipelinePhase)) }
            return try result.get()
        }
        func transform(instruction: String, selection: String, mode: Mode) async throws -> String {
            "transformed"
        }
    }

    @MainActor
    final class ObservingInjector: ClipboardInjecting {
        weak var state: AppState?
        private(set) var injected: [String] = []
        private(set) var observed: [Observation] = []
        func inject(_ text: String) async throws -> TextInsertionOutcome {
            injected.append(text)
            if let state { observed.append(Observation(isCancellable: state.isCancellable, phase: state.pipelinePhase)) }
            return TextInsertionOutcome(strategy: .clipboardPaste, verification: .unverified)
        }
    }

    struct Harness {
        let pipe: CapturePipeline
        let state: AppState
        let capture: FakeCapture
        let engine: FakeTranscriptionEngine
        let provider: FakeEngineProvider
        let session: FakeTranscriptionSession
        let llm: ObservingLLM
        let frontmost: LockedFrontmost
        let inspector: LockedFieldInspector
        let injector: ObservingInjector
        let selection: FakeSelectionSnapshot
        let history: DictationHistoryStore
    }

    nonisolated static let slack = "com.tinyspeck.slackmacgap"
    nonisolated static let searchField = FocusedField(role: "AXTextField", subrole: "AXSearchField")

    private func makeHarness(
        transcript: String = "hello world",
        vocabulary: [String] = [],
        skipShortUtterances: Bool = false,
        frontmostBundleID: String? = slack,
        focusedField: FocusedField? = nil
    ) -> Harness {
        let state = AppState()
        let capture = FakeCapture()
        let engine = FakeTranscriptionEngine()
        let session = FakeTranscriptionSession()
        session.finishResult = .success(transcript)
        engine.nextSessions = [session]
        let provider = FakeEngineProvider(engine)
        let llm = ObservingLLM()
        llm.state = state
        let injector = ObservingInjector()
        injector.state = state
        let frontmost = LockedFrontmost(frontmostBundleID)
        let inspector = LockedFieldInspector(focusedField)
        let selection = FakeSelectionSnapshot()
        let modes = ModeRouter(modes: [
            Mode(bundleID: Self.slack, displayName: "Slack", prompt: "slack-prompt", model: nil, temperature: nil),
            Mode(bundleID: Self.slack, displayName: "Slack search", prompt: "slack-search-prompt", model: nil, temperature: nil, fieldKind: .search),
            Mode(bundleID: "*", displayName: "Default", prompt: "default-prompt", model: nil, temperature: nil)
        ])
        let suiteName = "voxline-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let history = DictationHistoryStore(defaults: defaults)
        let pipe = CapturePipeline(
            state: state,
            capture: capture,
            engines: provider,
            llm: llm,
            modes: modes,
            frontmost: frontmost,
            fieldInspector: inspector,
            injector: injector,
            historyStore: history,
            contextCapture: FakeContextCapture(),
            selectionSnapshot: selection,
            llmModelID: { "test-model" },
            vocabulary: { vocabulary },
            skipShortUtterances: { skipShortUtterances }
        )
        pipe.transcriptFallback = { _ in }
        return Harness(
            pipe: pipe, state: state, capture: capture, engine: engine, provider: provider,
            session: session, llm: llm, frontmost: frontmost, inspector: inspector,
            injector: injector, selection: selection, history: history
        )
    }

    private func eventually(timeout: Duration = .seconds(2), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return true
    }

    // MARK: - Live partials

    @Test func streams_partials_into_liveTranscript() async {
        let h = makeHarness()
        h.pipe.startRecording()
        h.session.emit(.init(stable: "hello", volatile: "wor"))

        #expect(await eventually { h.state.liveTranscript != nil })
        #expect(h.state.liveTranscript?.text == "hello wor")

        h.session.emit(.init(stable: "hello world", volatile: ""))
        #expect(await eventually { h.state.liveTranscript?.text == "hello world" })
    }

    @Test func first_partial_metric_recorded() async throws {
        let h = makeHarness()
        h.pipe.startRecording()
        h.session.emit(.init(stable: "", volatile: ""))
        h.session.emit(.init(stable: "", volatile: "hel"))
        #expect(await eventually { h.state.liveTranscript?.isEmpty == false })
        await h.pipe.finalizeRecording()

        let row = try #require(h.pipe.metrics.items.first)
        let firstPartial = try #require(row.firstPartialMs)
        #expect(firstPartial >= 0)
    }

    @Test func no_partial_records_nil_first_partial() async throws {
        let h = makeHarness()
        h.pipe.startRecording()
        h.session.emit(.init(stable: "", volatile: ""))
        await h.pipe.finalizeRecording()

        let row = try #require(h.pipe.metrics.items.first)
        #expect(row.firstPartialMs == nil)
    }

    @Test func idle_clears_live_transcript_and_phase() async {
        let h = makeHarness()
        h.pipe.startRecording()
        h.session.emit(.init(stable: "hello", volatile: ""))
        #expect(await eventually { h.state.liveTranscript != nil })
        await h.pipe.finalizeRecording()

        #expect(h.state.status == .idle)
        #expect(h.state.liveTranscript == nil)
        #expect(h.state.pipelinePhase == nil)
    }

    @Test func next_start_clears_previous_live_transcript() async {
        let h = makeHarness()
        h.state.liveTranscript = TranscriptPartial(stable: "stale")
        h.pipe.startRecording()
        #expect(h.state.liveTranscript == nil)
    }

    // MARK: - Session lifecycle

    @Test func session_opens_with_vocabulary_hints() async {
        let h = makeHarness(vocabulary: ["Voxline", "WhisperKit"])
        h.pipe.startRecording()
        await h.pipe.finalizeRecording()
        #expect(h.engine.openedConfigs.map(\.vocabularyHints) == [["Voxline", "WhisperKit"]])
    }

    @Test func early_audio_reaches_session_after_open() async {
        let h = makeHarness()
        h.pipe.startRecording()
        #expect(h.engine.sessions.isEmpty, "the fake delivers audio inside start(), before any session opens")
        await h.pipe.finalizeRecording()
        #expect(h.session.appendedSampleCount == 8_000)
        #expect(h.session.finishCount == 1)
    }

    @Test func short_recording_is_a_quiet_noop() async {
        let h = makeHarness()
        h.capture.pendingSamples = [Float](repeating: 0.1, count: 1_600)
        h.pipe.startRecording()
        await h.pipe.finalizeRecording()

        #expect(h.state.status == .idle)
        #expect(h.llm.calls.isEmpty)
        #expect(h.injector.injected.isEmpty)
        #expect(h.state.toastMessage == nil)
        #expect(h.session.cancelCount == 1)
        #expect(h.session.finishCount == 0)
        #expect(h.pipe.metrics.items.isEmpty)
        #expect(h.state.isCancellable == false)
    }

    @Test func zero_samples_is_a_quiet_noop() async {
        let h = makeHarness()
        h.capture.pendingSamples = []
        h.pipe.startRecording()
        await h.pipe.finalizeRecording()

        #expect(h.state.status == .idle)
        #expect(h.llm.calls.isEmpty)
        #expect(h.session.cancelCount == 1)
    }

    @Test func short_silent_tap_is_quiet_not_a_microphone_error() async {
        let h = makeHarness()
        h.capture.pendingSamples = [Float](repeating: 0, count: 1_600)
        h.pipe.startRecording()
        await h.pipe.finalizeRecording()
        #expect(h.state.status == .idle)
    }

    @Test func silent_capture_errors_and_cancels_session() async {
        let h = makeHarness()
        h.capture.pendingSamples = [Float](repeating: 0, count: 16_000)
        h.pipe.startRecording()
        await h.pipe.finalizeRecording()

        guard case .error(let message) = h.state.status else {
            Issue.record("expected .error, got \(h.state.status)"); return
        }
        #expect(message.hasPrefix("No audio captured."))
        #expect(h.session.cancelCount == 1)
        #expect(h.llm.calls.isEmpty)
    }

    @Test func session_open_failure_reports_engine() async {
        let h = makeHarness()
        h.engine.openError = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "model missing"])
        h.pipe.startRecording()
        await h.pipe.finalizeRecording()

        guard case .error(let message) = h.state.status else {
            Issue.record("expected .error, got \(h.state.status)"); return
        }
        #expect(message.hasPrefix("Couldn't start"))
        #expect(message == "Couldn't start Whisper: model missing")
        #expect(h.llm.calls.isEmpty)
    }

    @Test func session_open_failure_names_apple_speech() async {
        let h = makeHarness()
        let apple = FakeTranscriptionEngine(id: .apple, metricsID: "fake:apple")
        apple.openError = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "no assets"])
        h.provider.engines[.apple] = apple
        h.provider.currentID = .apple
        h.pipe.startRecording()
        await h.pipe.finalizeRecording()
        #expect(h.state.status == .error("Couldn't start Apple Speech: no assets"))
    }

    @Test func finish_failure_uses_engine_neutral_message() async {
        struct Boom: Error {}
        let h = makeHarness()
        h.session.finishResult = .failure(Boom())
        h.pipe.startRecording()
        await h.pipe.finalizeRecording()
        #expect(h.state.status == .error("Transcription failed. Try again or pick a different engine in Settings → General."))
        #expect(h.state.liveTranscript == nil)
        #expect(h.state.isCancellable == false)
    }

    @Test func engine_is_fixed_at_recording_start() async throws {
        let h = makeHarness()
        let other = FakeTranscriptionEngine(id: .apple, metricsID: "fake:apple")
        h.provider.engines[.apple] = other
        h.pipe.startRecording()
        h.provider.currentID = .apple
        await h.pipe.finalizeRecording()

        #expect(h.session.finishCount == 1)
        #expect(other.openedConfigs.isEmpty)
        let row = try #require(h.pipe.metrics.items.first)
        #expect(row.engineID == "fake:engine")
    }

    @Test func phase_is_transcribing_while_finish_runs() async {
        let h = makeHarness()
        h.session.holdFinish = true
        h.pipe.startRecording()
        let finalize = Task { await h.pipe.finalizeRecording() }
        #expect(await eventually { h.session.finishCount == 1 })
        #expect(h.state.status == .thinking)
        #expect(h.state.pipelinePhase == .transcribing)
        #expect(h.state.isCancellable == true)
        h.session.releaseFinish()
        await finalize.value
        #expect(h.state.status == .idle)
    }

    // MARK: - Start snapshot

    @Test func mode_uses_start_snapshot() async throws {
        let h = makeHarness(focusedField: Self.searchField)
        h.pipe.startRecording()
        #expect(await eventually { h.frontmost.reads > 0 && h.inspector.reads > 0 })
        h.frontmost.bundleID = "com.example.other"
        h.inspector.field = nil
        await h.pipe.finalizeRecording()

        let call = try #require(h.llm.calls.first)
        #expect(call.mode.bundleID == Self.slack)
        #expect(call.mode.prompt == "slack-search-prompt")
    }

    // MARK: - Fast path

    @Test func fast_path_skips_cleanup_when_enabled() async throws {
        let h = makeHarness(transcript: "Sounds good.", skipShortUtterances: true)
        h.pipe.startRecording()
        await h.pipe.finalizeRecording()

        #expect(h.llm.calls.isEmpty)
        #expect(h.injector.injected == ["Sounds good."])
        let row = try #require(h.pipe.metrics.items.first)
        #expect(row.skippedCleanup == true)
        #expect(row.cleanupMs == 0)
        let item = try #require(h.history.items.first)
        #expect(item.cleanedText == "Sounds good.")
        #expect(item.rawTranscript == "Sounds good.")
    }

    @Test func fast_path_off_by_default_still_cleans() async throws {
        let h = makeHarness(transcript: "Sounds good.")
        h.pipe.startRecording()
        await h.pipe.finalizeRecording()

        #expect(h.llm.calls.count == 1)
        #expect(h.injector.injected == ["cleaned"])
        #expect(try #require(h.pipe.metrics.items.first).skippedCleanup == false)
    }

    @Test func fast_path_still_cleans_fillers() async {
        let h = makeHarness(transcript: "Um, sounds good.", skipShortUtterances: true)
        h.pipe.startRecording()
        await h.pipe.finalizeRecording()
        #expect(h.llm.calls.count == 1)
        #expect(h.injector.injected == ["cleaned"])
    }

    // MARK: - Retry transcript and cancellability

    @Test func retryTranscript_set_after_dictation_and_cleared_on_next_start() async {
        let h = makeHarness()
        h.pipe.startRecording()
        await h.pipe.finalizeRecording()
        #expect(h.state.retryTranscript == "hello world")

        h.pipe.startRecording()
        #expect(h.state.retryTranscript == nil)
    }

    @Test func retryTranscript_survives_a_cleanup_failure() async {
        let h = makeHarness()
        h.llm.result = .failure(LLMError.rateLimited)
        h.pipe.startRecording()
        await h.pipe.finalizeRecording()
        if case .error = h.state.status {} else { Issue.record("expected .error, got \(h.state.status)") }
        #expect(h.state.retryTranscript == "hello world")
    }

    @Test func retryTranscript_not_set_for_commands() async {
        let h = makeHarness()
        h.selection.selection = "original text"
        h.pipe.startRecording(command: true)
        await h.pipe.finalizeRecording()
        #expect(h.injector.injected == ["transformed"])
        #expect(h.state.retryTranscript == nil)
    }

    @Test func retryTranscript_not_set_for_empty_transcript() async {
        let h = makeHarness(transcript: "")
        h.pipe.startRecording()
        await h.pipe.finalizeRecording()
        #expect(h.state.status == .idle)
        #expect(h.state.retryTranscript == nil)
    }

    @Test func isCancellable_true_while_recording_false_after_insert() async {
        let h = makeHarness()
        #expect(h.state.isCancellable == false)
        h.pipe.startRecording()
        #expect(h.state.isCancellable == true)
        await h.pipe.finalizeRecording()

        #expect(h.llm.observed == [Observation(isCancellable: true, phase: .cleaning)])
        #expect(h.injector.observed == [Observation(isCancellable: false, phase: .inserting)])
        #expect(h.state.isCancellable == false)
        #expect(h.state.status == .idle)
    }

    // MARK: - Capture interruption

    @Test func capture_interruption_finalizes_with_toast() async {
        let h = makeHarness()
        h.pipe.startRecording()
        h.pipe.handleCaptureInterrupted()
        #expect(h.state.toastMessage == "Microphone disconnected — stopped recording")

        #expect(await eventually { h.state.status == .idle && !h.injector.injected.isEmpty })
        #expect(h.llm.calls.count == 1)
        #expect(h.capture.stopCallCount == 1)

        await h.pipe.finalizeRecording()
        #expect(h.llm.calls.count == 1, "the later key release must not finalize twice")
        #expect(h.capture.stopCallCount == 1)
    }

    @Test func capture_interruption_when_not_recording_is_ignored() async {
        let h = makeHarness()
        h.pipe.handleCaptureInterrupted()
        #expect(h.state.toastMessage == nil)
        #expect(h.state.status == .idle)
        #expect(h.capture.stopCallCount == 0)
    }
}
