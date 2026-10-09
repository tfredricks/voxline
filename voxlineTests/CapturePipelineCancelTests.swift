import Testing
import Foundation
@testable import voxline

/// Polls `condition` until it holds or `timeout` passes; never waits longer.
@MainActor
private func eventually(timeout: Duration = .seconds(2), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now >= deadline { return false }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return true
}

/// True when `task` completes within `timeout`; never waits longer.
@MainActor
func finishes(_ task: Task<Void, Never>, within timeout: Duration) async -> Bool {
    let finished = CapturePipelineStreamingTests.Flag()
    Task { await task.value; finished.set() }
    return await eventually(timeout: timeout) { finished.isSet }
}

@Suite(.timeLimit(.minutes(1))) @MainActor struct CapturePipelineCancelTests {

    typealias FakeCapture = CapturePipelineTests.FakeCapture
    typealias FakeLLM = CapturePipelineTests.FakeLLM
    typealias FakeInjector = CapturePipelineTests.FakeInjector
    typealias FakeSelectionSnapshot = CapturePipelineTests.FakeSelectionSnapshot
    typealias LockedFrontmost = CapturePipelineStreamingTests.LockedFrontmost
    typealias LockedFieldInspector = CapturePipelineStreamingTests.LockedFieldInspector

    /// Holds every capture until `gate` opens, then reports whether the task
    /// running it had been cancelled by then.
    final class CancellationProbingContext: ContextCapturing, @unchecked Sendable {
        let gate = TestGate()
        private let lock = NSLock()
        private var _outcomes: [String] = []
        var outcomes: [String] { lock.withLock { _outcomes } }
        func capture() async -> CapturedContext {
            await gate.wait()
            let outcome = Task.isCancelled ? "cancelled" : "live"
            lock.withLock { _outcomes.append(outcome) }
            var context = CapturedContext.empty
            context.appName = outcome
            return context
        }
    }

    struct Harness {
        let pipe: CapturePipeline
        let state: AppState
        let capture: FakeCapture
        let engine: FakeTranscriptionEngine
        let session: FakeTranscriptionSession
        let llm: FakeLLM
        let frontmost: LockedFrontmost
        let inspector: LockedFieldInspector
        let injector: FakeInjector
        let selection: FakeSelectionSnapshot
        let history: DictationHistoryStore
        let context: any ContextCapturing
        let fallback: LockedBox<[String]>
    }

    nonisolated static let slack = "com.tinyspeck.slackmacgap"

    private func makeHarness(
        transcript: String = "hello world",
        skipShortUtterances: Bool = false,
        focusedField: FocusedField? = nil,
        context: any ContextCapturing = FakeContextCapture()
    ) -> Harness {
        let state = AppState()
        let capture = FakeCapture()
        let engine = FakeTranscriptionEngine()
        let session = FakeTranscriptionSession()
        session.finishResult = .success(transcript)
        engine.nextSessions = [session]
        let llm = FakeLLM()
        let injector = FakeInjector()
        let frontmost = LockedFrontmost(Self.slack)
        let inspector = LockedFieldInspector(focusedField)
        let selection = FakeSelectionSnapshot()
        let suiteName = "voxline-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let history = DictationHistoryStore(defaults: defaults)
        let pipe = CapturePipeline(
            state: state,
            capture: capture,
            engines: FakeEngineProvider(engine),
            llm: llm,
            modes: ModeRouter(modes: [
                Mode(bundleID: Self.slack, displayName: "Slack", prompt: "slack-prompt", model: nil, temperature: nil, category: .chat),
                Mode(bundleID: "*", displayName: "Default", prompt: "default-prompt", model: nil, temperature: nil, category: .general)
            ]),
            frontmost: frontmost,
            fieldInspector: inspector,
            injector: injector,
            historyStore: history,
            contextCapture: context,
            selectionSnapshot: selection,
            llmModelID: { "test-model" },
            vocabulary: { [] },
            skipShortUtterances: { skipShortUtterances }
        )
        let fallback = LockedBox<[String]>([])
        pipe.transcriptFallback = { text in fallback.mutate { $0.append(text) } }
        return Harness(
            pipe: pipe, state: state, capture: capture, engine: engine, session: session,
            llm: llm, frontmost: frontmost, inspector: inspector, injector: injector,
            selection: selection, history: history, context: context, fallback: fallback
        )
    }

    private func dictate(_ h: Harness) async {
        h.pipe.startRecording()
        await h.pipe.finalizeRecording()
    }

    // MARK: - Cancel while recording

    @Test func cancel_while_recording_discards() async {
        let h = makeHarness()
        h.session.keepsPartialsOpen = true
        h.pipe.startRecording()
        #expect(await eventually { h.engine.sessions.count == 1 })
        h.pipe.cancel()

        #expect(h.state.status == .idle)
        #expect(h.session.cancelCount == 1)
        #expect(h.session.finishCount == 0)
        #expect(h.capture.stopCallCount == 1)
        #expect(h.capture.onSamples == nil)
        #expect(h.state.toastMessage == "Cancelled")
        #expect(h.state.isCancellable == false)
        #expect(h.state.liveTranscript == nil)
        #expect(h.pipe.wasCancelled)

        h.session.emit(.init(stable: "late", volatile: ""))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(h.state.liveTranscript == nil)

        await h.pipe.finalizeRecording()
        #expect(h.llm.calls.isEmpty, "the chord release after Esc finalizes nothing")
        #expect(h.injector.injected.isEmpty)
        #expect(h.capture.stopCallCount == 1)
        #expect(h.history.items.isEmpty)
        #expect(h.pipe.metrics.items.isEmpty)
    }

    @Test func cancel_before_the_session_opens_cancels_it_once_open() async {
        let h = makeHarness()
        h.pipe.startRecording()
        #expect(h.engine.sessions.isEmpty)
        h.pipe.cancel()

        #expect(h.state.status == .idle)
        #expect(await eventually { h.session.cancelCount == 1 })
        #expect(h.session.finishCount == 0)
    }

    @Test func wasCancelled_clears_on_next_start() {
        let h = makeHarness()
        h.pipe.startRecording()
        h.pipe.cancel()
        #expect(h.pipe.wasCancelled)
        h.pipe.startRecording()
        #expect(!h.pipe.wasCancelled)
    }

    // MARK: - Cancel while thinking

    @Test func cancel_while_transcribing_returns_promptly() async {
        let h = makeHarness()
        h.session.holdFinish = true
        h.session.ignoresCancel = true
        defer { h.session.releaseFinish() }
        h.pipe.startRecording()
        let finalize = Task { await h.pipe.finalizeRecording() }
        #expect(await eventually { h.session.finishCount == 1 })
        #expect(h.state.status == .thinking)

        h.pipe.cancel()
        #expect(await finishes(finalize, within: .milliseconds(200)))
        #expect(h.state.status == .idle)
        #expect(h.state.toastMessage == "Cancelled")
        #expect(h.session.cancelCount == 1)

        h.session.releaseFinish()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(h.llm.calls.isEmpty)
        #expect(h.injector.injected.isEmpty)
        #expect(h.history.items.isEmpty)
        #expect(h.pipe.metrics.items.isEmpty)
        #expect(h.state.status == .idle)
        #expect(h.state.lastTranscript == nil)
        #expect(h.state.retryTranscript == nil)
    }

    @Test func cancel_while_transcribing_cancels_the_session_without_an_error() async {
        let h = makeHarness()
        h.session.holdFinish = true
        h.pipe.startRecording()
        let finalize = Task { await h.pipe.finalizeRecording() }
        #expect(await eventually { h.session.finishCount == 1 })

        h.pipe.cancel()
        #expect(await finishes(finalize, within: .milliseconds(200)))
        try? await Task.sleep(for: .milliseconds(20))

        #expect(h.session.cancelCount == 1)
        #expect(h.state.status == .idle)
        #expect(h.state.toastMessage == "Cancelled")
        #expect(h.llm.calls.isEmpty)
    }

    @Test func cancel_while_cleaning_keeps_transcript_in_history_and_retry() async throws {
        let h = makeHarness()
        h.llm.holdCleanup = true
        defer { h.llm.releaseCleanup() }
        h.pipe.startRecording()
        let finalize = Task { await h.pipe.finalizeRecording() }
        #expect(await eventually { h.llm.cleanupGate.waiting == 1 })
        #expect(h.state.pipelinePhase == .cleaning)

        h.pipe.cancel()
        #expect(await finishes(finalize, within: .milliseconds(200)))
        #expect(h.state.status == .idle)
        #expect(h.state.toastMessage == "Cancelled")
        #expect(h.history.items.count == 1)
        let item = try #require(h.history.items.first)
        #expect(item.cleanedText == "hello world")
        #expect(item.rawTranscript == "hello world")
        #expect(item.modeCategoryName == "Chat")
        #expect(h.state.retryTranscript == "hello world")

        h.llm.releaseCleanup()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(h.injector.injected.isEmpty)
        #expect(h.history.items.count == 1)
        #expect(h.pipe.metrics.items.isEmpty)
        #expect(h.state.status == .idle)
    }

    @Test func cancel_while_transforming_records_nothing() async {
        let h = makeHarness()
        h.selection.selection = "original text"
        h.llm.holdCleanup = true
        defer { h.llm.releaseCleanup() }
        h.pipe.startRecording(command: true)
        let finalize = Task { await h.pipe.finalizeRecording() }
        #expect(await eventually { h.llm.cleanupGate.waiting == 1 })

        h.pipe.cancel()
        #expect(await finishes(finalize, within: .milliseconds(200)))
        #expect(h.state.status == .idle)
        #expect(h.state.toastMessage == "Cancelled")
        #expect(h.history.items.isEmpty)
        #expect(h.state.retryTranscript == nil)

        h.llm.releaseCleanup()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(h.injector.injected.isEmpty)
    }

    @Test func cancel_during_insert_is_ignored() async {
        let h = makeHarness()
        h.injector.holdInject = true
        defer { h.injector.releaseInject() }
        h.pipe.startRecording()
        let finalize = Task { await h.pipe.finalizeRecording() }
        #expect(await eventually { h.injector.injectGate.waiting == 1 })
        #expect(h.state.isCancellable == false)
        #expect(h.state.pipelinePhase == .inserting)

        h.pipe.cancel()
        #expect(h.state.status == .thinking)
        #expect(h.state.toastMessage == nil)
        #expect(!h.pipe.wasCancelled)

        h.injector.releaseInject()
        #expect(await finishes(finalize, within: .seconds(2)))
        #expect(h.injector.injected == ["cleaned"])
        #expect(h.state.status == .idle)
        #expect(h.pipe.metrics.items.count == 1)
    }

    @Test(arguments: [AppStatus.idle, .error("boom"), .permissionsError("nope"), .preparingModel])
    func cancel_when_nothing_is_running_does_nothing(status: AppStatus) {
        let h = makeHarness()
        h.state.status = status
        h.pipe.cancel()
        #expect(h.state.status == status)
        #expect(h.state.toastMessage == nil)
        #expect(!h.pipe.wasCancelled)
    }

    // MARK: - Late results never reach a newer recording

    @Test func stale_finalize_leaves_the_next_recording_untouched() async {
        let probe = CancellationProbingContext()
        let h = makeHarness(context: probe)
        h.session.holdFinish = true
        h.session.ignoresCancel = true
        defer {
            h.session.releaseFinish()
            probe.gate.open()
        }
        let second = FakeTranscriptionSession()
        second.finishResult = .success("second take")
        h.engine.nextSessions.append(second)

        h.pipe.startRecording()
        let first = Task { await h.pipe.finalizeRecording() }
        #expect(await eventually { h.session.finishCount == 1 })
        h.pipe.cancel()
        #expect(await finishes(first, within: .milliseconds(200)))

        h.pipe.startRecording()
        #expect(await eventually { h.engine.sessions.count == 2 })
        second.emit(.init(stable: "second", volatile: ""))
        #expect(await eventually { h.state.liveTranscript?.text == "second" })

        h.session.releaseFinish()
        try? await Task.sleep(for: .milliseconds(50))

        #expect(h.state.status == .recording)
        #expect(h.state.isCancellable)
        #expect(h.state.liveTranscript?.text == "second")
        #expect(h.capture.onSamples != nil)
        #expect(second.cancelCount == 0)
        #expect(h.llm.calls.isEmpty)
        let before = second.appendedSampleCount
        h.capture.onSamples?([Float](repeating: 0.1, count: 160))
        #expect(second.appendedSampleCount == before + 160, "the new recording's router still feeds its session")

        probe.gate.open()
        await h.pipe.finalizeRecording()
        #expect(probe.outcomes.sorted() == ["cancelled", "live"], "the stale finalize cancels only its own start tasks")
        #expect(second.finishCount == 1)
        #expect(h.llm.calls.map(\.transcript) == ["second take"])
        #expect(h.llm.calls.first?.context.appName == "live")
        #expect(h.llm.calls.first?.mode.bundleID == Self.slack)
        #expect(h.injector.injected == ["cleaned"])
        #expect(h.state.status == .idle)
    }

    @Test func interruption_finalize_skips_a_newer_recording() async {
        let h = makeHarness()
        let second = FakeTranscriptionSession()
        h.engine.nextSessions.append(second)
        h.pipe.startRecording()
        h.pipe.handleCaptureInterrupted()
        h.pipe.cancel()
        h.pipe.startRecording()
        try? await Task.sleep(for: .milliseconds(50))

        #expect(h.state.status == .recording)
        #expect(h.capture.stopCallCount == 1)
        #expect(second.finishCount == 0)
        #expect(h.llm.calls.isEmpty)
    }

    // MARK: - Retry

    @Test func failed_start_scrubs_the_previous_transcript() async {
        struct Boom: Error {}
        let h = makeHarness()
        await dictate(h)
        #expect(h.state.retryTranscript == "hello world")

        h.capture.startError = Boom()
        h.pipe.startRecording()
        guard case .error(let message) = h.state.status else {
            Issue.record("expected .error, got \(h.state.status)"); return
        }
        #expect(message.hasPrefix("Audio capture failed"))
        #expect(h.state.retryTranscript == nil)
        #expect(h.state.lastTranscript == nil)
        #expect(h.state.lastCleanedText == nil)
        #expect(!PillLayout.offersRetry(status: h.state.status, hasRetryTranscript: h.state.retryTranscript != nil))

        await h.pipe.retryLastDictation()
        #expect(h.llm.calls.count == 1)
        #expect(h.injector.injected == ["cleaned"])
    }

    @Test func retry_reinserts_last_transcript() async {
        let h = makeHarness(transcript: "uh hello there")
        h.llm.nextResult = .success("Hello there.")
        await dictate(h)
        #expect(h.injector.injected == ["Hello there."])

        await h.pipe.retryLastDictation()
        #expect(h.llm.calls.map(\.transcript) == ["uh hello there", "uh hello there"])
        #expect(h.injector.injected == ["Hello there.", "Hello there."])
        #expect(h.state.status == .idle)
        #expect(h.state.retryTranscript == "uh hello there")
        #expect(h.history.items.count == 2)
        #expect(h.history.items.allSatisfy { $0.rawTranscript == "uh hello there" })
        #expect(h.pipe.metrics.items.count == 1, "retry records no metrics")
        #expect(h.state.isCancellable == false)
        #expect(h.state.pipelinePhase == nil)
    }

    @Test func retry_unavailable_without_transcript() async {
        let h = makeHarness()
        await h.pipe.retryLastDictation()
        #expect(h.llm.calls.isEmpty)
        #expect(h.injector.injected.isEmpty)
        #expect(h.history.items.isEmpty)
        #expect(h.state.status == .idle)
        #expect((h.context as? FakeContextCapture)?.captureCallCount == 0)
    }

    @Test(arguments: [AppStatus.recording, .thinking, .permissionsError("nope"), .downloadingModel(progress: 0.5)])
    func retry_refused_while_busy(status: AppStatus) async {
        let h = makeHarness()
        h.state.retryTranscript = "hello world"
        h.state.status = status
        await h.pipe.retryLastDictation()
        #expect(h.llm.calls.isEmpty)
        #expect(h.state.status == status)
    }

    @Test func retry_uses_the_app_focused_now() async {
        let h = makeHarness()
        await dictate(h)
        #expect(h.llm.calls.first?.mode.bundleID == Self.slack)

        h.frontmost.bundleID = "com.example.other"
        await h.pipe.retryLastDictation()
        #expect(h.llm.calls.last?.mode.bundleID == "*")
        #expect((h.context as? FakeContextCapture)?.captureCallCount == 2)
    }

    @Test func retry_recovers_from_a_cleanup_failure() async {
        let h = makeHarness()
        h.llm.nextResult = .failure(LLMError.rateLimited)
        await dictate(h)
        if case .error = h.state.status {} else { Issue.record("expected .error, got \(h.state.status)") }

        h.llm.nextResult = .success("cleaned")
        await h.pipe.retryLastDictation()
        #expect(h.injector.injected == ["cleaned"])
        #expect(h.state.status == .idle)
        #expect(h.history.items.count == 1)
    }

    @Test func retry_failure_uses_the_finalize_message() async {
        let h = makeHarness()
        await dictate(h)
        h.llm.nextResult = .failure(LLMError.rateLimited)

        await h.pipe.retryLastDictation()
        let expected = "\(LLMError.rateLimited.errorDescription ?? "") Raw transcript copied to the clipboard — paste to recover it."
        #expect(h.state.status == .error(expected))
        #expect(h.fallback.read() == ["hello world"])
        #expect(h.state.retryTranscript == "hello world")
    }

    @Test func retry_without_a_text_field_copies() async {
        let h = makeHarness()
        await dictate(h)
        h.inspector.field = FocusedField(role: "AXButton", subrole: nil)

        await h.pipe.retryLastDictation()
        #expect(h.injector.injected == ["cleaned"])
        #expect(h.fallback.read() == ["cleaned"])
        #expect(h.state.toastMessage == "No text field focused — copied")
        #expect(h.state.status == .idle)
    }

    @Test func retry_honors_the_fast_path() async {
        let h = makeHarness(transcript: "Sounds good.", skipShortUtterances: true)
        await dictate(h)
        await h.pipe.retryLastDictation()
        #expect(h.llm.calls.isEmpty)
        #expect(h.injector.injected == ["Sounds good.", "Sounds good."])
    }

    @Test func cancel_during_retry_drops_the_result_and_files_the_transcript() async {
        let h = makeHarness()
        await dictate(h)
        h.llm.holdCleanup = true
        defer { h.llm.releaseCleanup() }
        let retry = Task { await h.pipe.retryLastDictation() }
        #expect(await eventually { h.llm.cleanupGate.waiting == 1 })
        #expect(h.state.status == .thinking)
        #expect(h.state.pipelinePhase == .cleaning)
        #expect(h.state.isCancellable)

        h.pipe.cancel()
        #expect(await finishes(retry, within: .milliseconds(200)))
        #expect(h.state.status == .idle)
        #expect(h.state.toastMessage == "Cancelled")
        #expect(h.state.retryTranscript == "hello world")
        #expect(h.history.items.count == 2)
        #expect(h.history.items.first?.cleanedText == "hello world")
        #expect(h.history.items.first?.rawTranscript == "hello world")

        h.llm.releaseCleanup()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(h.injector.injected == ["cleaned"])
        #expect(h.history.items.count == 2)
    }

    @Test func cancel_during_retry_before_a_mode_skips_history() async {
        let probe = CancellationProbingContext()
        let h = makeHarness(context: probe)
        defer { probe.gate.open() }
        h.state.retryTranscript = "hello world"
        let retry = Task { await h.pipe.retryLastDictation() }
        #expect(await eventually { probe.gate.waiting == 1 })
        #expect(h.state.status == .thinking)

        h.pipe.cancel()
        #expect(await finishes(retry, within: .milliseconds(200)))
        #expect(h.state.status == .idle)
        #expect(h.history.items.isEmpty)
        #expect(h.state.retryTranscript == "hello world")

        probe.gate.open()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(h.llm.calls.isEmpty)
        #expect(h.injector.injected.isEmpty)
    }

    @Test func retry_after_a_cancel_inserts_the_kept_transcript() async {
        let h = makeHarness()
        h.llm.holdCleanup = true
        defer { h.llm.releaseCleanup() }
        h.pipe.startRecording()
        let finalize = Task { await h.pipe.finalizeRecording() }
        #expect(await eventually { h.llm.cleanupGate.waiting == 1 })
        h.pipe.cancel()
        #expect(await finishes(finalize, within: .milliseconds(200)))
        h.llm.releaseCleanup()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(h.injector.injected.isEmpty, "the cancelled cleanup's late result is dropped")

        h.llm.holdCleanup = false
        let retry = Task { await h.pipe.retryLastDictation() }
        #expect(await finishes(retry, within: .seconds(2)))
        #expect(h.injector.injected == ["cleaned"])
        #expect(h.state.status == .idle)
    }

    // MARK: - Recording cap

    @Test func cap_toast_follows_the_insert() async {
        let h = makeHarness()
        h.pipe.startRecording()
        h.pipe.capHit = true
        await h.pipe.finalizeRecording()
        #expect(h.injector.injected == ["cleaned"])
        #expect(h.state.toastMessage == "Stopped at 5 minutes")
        #expect(!h.pipe.capHit)
    }

    @Test func cap_toast_shows_on_the_error_path() async {
        let h = makeHarness()
        h.llm.nextResult = .failure(LLMError.rateLimited)
        h.pipe.startRecording()
        h.pipe.capHit = true
        await h.pipe.finalizeRecording()
        if case .error = h.state.status {} else { Issue.record("expected .error, got \(h.state.status)") }
        #expect(h.state.toastMessage == "Stopped at 5 minutes")
        #expect(!h.pipe.capHit)
    }

    @Test func cap_toast_never_hides_where_the_text_went() async {
        let h = makeHarness(focusedField: FocusedField(role: "AXButton", subrole: nil))
        h.pipe.startRecording()
        h.pipe.capHit = true
        await h.pipe.finalizeRecording()
        #expect(h.state.toastMessage == "No text field focused — copied")
        #expect(!h.pipe.capHit)
    }

    @Test func no_cap_toast_without_the_cap() async {
        let h = makeHarness()
        await dictate(h)
        #expect(h.state.toastMessage == nil)
    }

    @Test func cancel_clears_the_cap() {
        let h = makeHarness()
        h.pipe.startRecording()
        h.pipe.capHit = true
        h.pipe.cancel()
        #expect(!h.pipe.capHit)
        #expect(h.state.toastMessage == "Cancelled")
    }

    @Test func next_start_clears_the_cap() {
        let h = makeHarness()
        h.pipe.capHit = true
        h.pipe.startRecording()
        #expect(!h.pipe.capHit)
    }
}

@Suite(.timeLimit(.minutes(1))) @MainActor struct OneShotSignalTests {

    @Test func wait_after_fire_returns_at_once() async {
        let signal = OneShotSignal()
        signal.fire()
        let waiter = Task { await signal.wait() }
        #expect(await finishes(waiter, within: .seconds(1)))
    }

    @Test func fire_resumes_the_waiter() async {
        let signal = OneShotSignal()
        let waiter = Task { await signal.wait() }
        #expect(!(await finishes(waiter, within: .milliseconds(20))))

        signal.fire()
        #expect(await finishes(waiter, within: .seconds(1)))
    }

    @Test func second_fire_is_harmless() async {
        let signal = OneShotSignal()
        signal.fire()
        signal.fire()
        let waiter = Task { await signal.wait() }
        #expect(await finishes(waiter, within: .seconds(1)))
    }
}
