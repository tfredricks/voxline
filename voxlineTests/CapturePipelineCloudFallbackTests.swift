import Testing
import Foundation
@testable import voxline

@Suite(.timeLimit(.minutes(1))) @MainActor struct CapturePipelineCloudFallbackTests {

    typealias FakeCapture = CapturePipelineTests.FakeCapture
    typealias FakeLLM = CapturePipelineTests.FakeLLM
    typealias FakeSelectionSnapshot = CapturePipelineTests.FakeSelectionSnapshot
    typealias LockedFrontmost = CapturePipelineStreamingTests.LockedFrontmost
    typealias LockedFieldInspector = CapturePipelineStreamingTests.LockedFieldInspector

    struct Boom: Error {}

    struct Harness {
        let pipe: CapturePipeline
        let state: AppState
        let capture: FakeCapture
        let provider: FakeEngineProvider
        let cloud: FakeTranscriptionEngine
        let cloudSession: FakeTranscriptionSession
        let local: FakeTranscriptionEngine
        let localSession: FakeTranscriptionSession
        let llm: FakeLLM
        let inserter: FakeTextInserter
        let history: DictationHistoryStore
    }

    nonisolated static let slack = "com.tinyspeck.slackmacgap"
    static let fellBack = "Cloud transcription failed — used on-device"
    static let transcriptionFailed = "Transcription failed. Try again or pick a different engine in Settings → General."

    /// A cloud fake is current unless `current` replaces it; the on-device
    /// default is a fake whose session returns "local text".
    private func makeHarness(current: (any TranscriptionEngine)? = nil) -> Harness {
        let state = AppState()
        let capture = FakeCapture()
        let cloud = FakeTranscriptionEngine(id: .openAIRealtime, metricsID: "fake:cloud", capabilities: [.streamingPartials, .sendsAudioOffDevice])
        let cloudSession = FakeTranscriptionSession()
        cloudSession.finishResult = .success("cloud text")
        cloud.nextSessions = [cloudSession]
        let local = FakeTranscriptionEngine(id: .onDeviceDefault, metricsID: "fake:local")
        let localSession = FakeTranscriptionSession()
        localSession.finishResult = .success("local text")
        local.nextSessions = [localSession]
        let provider = FakeEngineProvider(current ?? cloud)
        provider.add(local)
        let llm = FakeLLM()
        let inserter = FakeTextInserter()
        let suiteName = "voxline-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let history = DictationHistoryStore(defaults: defaults)
        let pipe = CapturePipeline(
            state: state,
            capture: capture,
            engines: provider,
            llm: llm,
            modes: ModeRouter(modes: [
                Mode(bundleID: "*", displayName: "Default", prompt: "default-prompt", model: nil, temperature: nil)
            ]),
            frontmost: LockedFrontmost(Self.slack),
            fieldInspector: LockedFieldInspector(nil),
            inserter: inserter,
            historyStore: history,
            contextCapture: FakeContextCapture(),
            selectionSnapshot: FakeSelectionSnapshot(),
            llmModelID: { "test-model" },
            vocabulary: { ["Voxline"] },
            skipShortUtterances: { false },
            chords: { .default },
            saveBakeoffClips: { false }
        )
        pipe.transcriptFallback = { _ in }
        return Harness(
            pipe: pipe, state: state, capture: capture, provider: provider,
            cloud: cloud, cloudSession: cloudSession, local: local, localSession: localSession,
            llm: llm, inserter: inserter, history: history
        )
    }

    /// 2.5 s of distinct samples, so order and completeness are checkable.
    private static let speech: [Float] = (0..<40_000).map { 0.05 + Float($0 % 97) / 1_000 }

    private static func serverError(_ message: String) -> NSError {
        NSError(domain: OpenAIRealtimeEngine.errorDomain, code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func dictate(_ h: Harness) async {
        h.pipe.startRecording()
        await h.pipe.finalizeRecording()
    }

    // MARK: - Fallback succeeds

    @Test func finish_failure_reruns_the_retained_audio_on_device() async throws {
        let h = makeHarness()
        h.capture.pendingSamples = Self.speech
        h.cloudSession.finishResult = .failure(Self.serverError("Internal server error"))
        await dictate(h)

        #expect(h.cloudSession.appendedSampleCount == Self.speech.count)
        #expect(h.localSession.appended.map(\.count) == [16_000, 16_000, 8_000])
        #expect(h.localSession.appended.flatMap { $0 } == Self.speech)
        #expect(h.localSession.finishCount == 1)
        #expect(h.local.openedConfigs == h.cloud.openedConfigs)
        #expect(h.local.openedConfigs.map(\.vocabularyHints) == [["Voxline"]])
        #expect(h.llm.calls.map(\.transcript) == ["local text"])
        #expect(h.inserter.calls.map(\.text) == ["cleaned"])
        #expect(h.state.toastMessage == Self.fellBack)
        #expect(h.state.status == .idle)
        #expect(h.state.retryTranscript == "local text")
        let row = try #require(h.pipe.metrics.items.first)
        #expect(row.engineID == "fake:local")
        #expect(h.history.items.first?.rawTranscript == "local text")
    }

    /// The first partial came from the failed cloud session, so it says
    /// nothing about the transcript that was used.
    @Test func a_fallback_dictation_records_no_first_partial_time() async throws {
        let h = makeHarness()
        h.capture.pendingSamples = Self.speech
        h.cloudSession.finishResult = .failure(Self.serverError("Internal server error"))
        h.pipe.startRecording()
        h.cloudSession.emit(TranscriptPartial(stable: "", volatile: "cloud"))
        #expect(await eventually { h.state.liveTranscript?.isEmpty == false })
        await h.pipe.finalizeRecording()

        let row = try #require(h.pipe.metrics.items.first)
        #expect(row.engineID == "fake:local")
        #expect(row.firstPartialMs == nil)
    }

    @Test func open_failure_reruns_the_retained_audio_on_device() async throws {
        let h = makeHarness()
        h.capture.pendingSamples = Self.speech
        h.cloud.openError = Self.serverError("OpenAI rejected the API key.")
        await dictate(h)

        #expect(h.cloud.sessions.isEmpty)
        #expect(h.localSession.appended.flatMap { $0 } == Self.speech)
        #expect(h.local.openedConfigs == h.cloud.openedConfigs)
        #expect(h.llm.calls.map(\.transcript) == ["local text"])
        #expect(h.inserter.calls.map(\.text) == ["cleaned"])
        #expect(h.state.toastMessage == Self.fellBack)
        #expect(h.state.status == .idle)
        #expect(try #require(h.pipe.metrics.items.first).engineID == "fake:local")
    }

    /// OpenAI fails the whole dictation when one VAD segment fails to
    /// transcribe, even after an earlier segment completed. The fallback
    /// re-transcribes the entire recording on-device.
    @Test func a_failed_openai_segment_is_recovered_on_device() async throws {
        let transport = FakeRealtimeTransport { sent in
            switch sent["type"] as? String {
            case "input_audio_buffer.commit":
                return [
                    ["type": "input_audio_buffer.committed", "item_id": "item_2", "previous_item_id": "item_1"],
                    ["type": "conversation.item.input_audio_transcription.failed", "item_id": "item_2", "content_index": 0,
                     "error": ["type": "transcription_error", "code": "audio_unintelligible", "message": "Audio could not be transcribed."]],
                ]
            case "input_audio_buffer.clear":
                return [["type": "input_audio_buffer.cleared"]]
            default:
                return []
            }
        }
        transport.push(["type": "input_audio_buffer.committed", "item_id": "item_1", "previous_item_id": NSNull()])
        transport.push(["type": "conversation.item.input_audio_transcription.completed", "item_id": "item_1", "content_index": 0, "transcript": "First part."])
        let openAI = OpenAIRealtimeEngine(
            keychain: InMemoryKeychain(seed: [KeychainAccount.openai: "sk-test-key"]),
            transport: { _ in transport }
        )
        let h = makeHarness(current: openAI)
        await dictate(h)

        #expect(transport.sentTypes.contains("input_audio_buffer.commit"))
        #expect(h.localSession.appendedSampleCount == h.capture.pendingSamples.count)
        #expect(h.llm.calls.map(\.transcript) == ["local text"])
        #expect(h.inserter.calls.map(\.text) == ["cleaned"])
        #expect(h.state.toastMessage == Self.fellBack)
        #expect(try #require(h.pipe.metrics.items.first).engineID == "fake:local")
    }

    // MARK: - Fallback fails

    @Test func a_failed_fallback_after_an_open_failure_reports_the_open_failure() async {
        let h = makeHarness()
        h.cloud.openError = Self.serverError("OpenAI rejected the API key.")
        h.local.openError = Self.serverError("model missing")
        await dictate(h)

        #expect(h.state.status == .error("Couldn't start OpenAI: OpenAI rejected the API key."))
        #expect(h.state.toastMessage == nil)
        #expect(h.llm.calls.isEmpty)
        #expect(h.inserter.calls.isEmpty)
        #expect(h.pipe.metrics.items.isEmpty)
        #expect(h.state.isCancellable == false)
    }

    @Test func a_failed_fallback_after_a_finish_failure_reports_the_transcription_failure() async {
        let h = makeHarness()
        h.cloudSession.finishResult = .failure(Self.serverError("Internal server error"))
        h.localSession.finishResult = .failure(Boom())
        await dictate(h)

        #expect(h.localSession.finishCount == 1)
        #expect(h.state.status == .error(Self.transcriptionFailed))
        #expect(h.state.toastMessage == nil)
        #expect(h.llm.calls.isEmpty)
        #expect(h.inserter.calls.isEmpty)
    }

    // MARK: - No fallback

    @Test func a_cancelled_cloud_finish_does_not_fall_back() async {
        let h = makeHarness()
        h.cloudSession.finishResult = .failure(CancellationError())
        await dictate(h)

        #expect(h.local.openedConfigs.isEmpty)
        #expect(h.state.status == .error(Self.transcriptionFailed))
        #expect(h.state.toastMessage == nil)
    }

    @Test func a_cancelled_cloud_open_does_not_fall_back() async {
        let h = makeHarness()
        h.cloud.openError = CancellationError()
        await dictate(h)

        #expect(h.local.openedConfigs.isEmpty)
        guard case .error(let message) = h.state.status else {
            Issue.record("expected .error, got \(h.state.status)"); return
        }
        #expect(message.hasPrefix("Couldn't start OpenAI: "))
    }

    /// A fallback never downloads or installs a model, so an on-device engine
    /// that isn't ready right now is never opened.
    @Test(arguments: [EngineReadiness.needsPreparation(downloadMB: 1_500), .unavailable("Speech assets aren't installed.")])
    func a_finish_failure_does_not_fall_back_to_an_engine_that_isnt_ready(readiness: EngineReadiness) async {
        let h = makeHarness()
        h.local.readinessValue = readiness
        h.cloudSession.finishResult = .failure(Self.serverError("Internal server error"))
        await dictate(h)

        #expect(h.local.openedConfigs.isEmpty)
        #expect(h.local.prepareCount == 0)
        #expect(h.state.status == .error(Self.transcriptionFailed))
        #expect(h.state.toastMessage == nil)
        #expect(h.llm.calls.isEmpty)
        #expect(h.inserter.calls.isEmpty)
    }

    @Test func an_open_failure_does_not_fall_back_to_an_engine_that_isnt_ready() async {
        let h = makeHarness()
        h.local.readinessValue = .needsPreparation(downloadMB: 1_500)
        h.cloud.openError = Self.serverError("The network connection was lost.")
        await dictate(h)

        #expect(h.local.openedConfigs.isEmpty)
        #expect(h.local.prepareCount == 0)
        #expect(h.state.status == .error("Couldn't start OpenAI: The network connection was lost."))
        #expect(h.state.toastMessage == nil)
    }

    /// A missing (or blank) key is a setting to fix, not an outage: falling
    /// back would hide it behind a toast on every dictation.
    @Test(arguments: [[:], [KeychainAccount.openai: "   "]])
    func a_missing_openai_key_shows_its_error_instead_of_falling_back(keychain: [String: String]) async {
        let openAI = OpenAIRealtimeEngine(
            keychain: InMemoryKeychain(seed: keychain),
            transport: { _ in
                Issue.record("no connection without a key")
                return FakeRealtimeTransport()
            }
        )
        let h = makeHarness(current: openAI)
        await dictate(h)

        #expect(h.local.openedConfigs.isEmpty)
        #expect(h.state.status == .error(OpenAIRealtimeEngine.missingKeyReason))
        #expect(h.state.toastMessage == nil)
        #expect(h.llm.calls.isEmpty)
        #expect(h.inserter.calls.isEmpty)
        #expect(h.pipe.metrics.items.isEmpty)
    }

    /// An unreadable keychain is a setup problem like a missing key, and
    /// says so instead of asking for a key the user already stored.
    @Test func an_unreadable_openai_key_shows_its_error_instead_of_falling_back() async {
        let keychain = InMemoryKeychain(seed: [KeychainAccount.openai: "sk-test-key"])
        keychain.readError = KeychainError.dataProtectionKeychainUnavailable
        let openAI = OpenAIRealtimeEngine(
            keychain: keychain,
            transport: { _ in
                Issue.record("no connection without a readable key")
                return FakeRealtimeTransport()
            }
        )
        let h = makeHarness(current: openAI)
        await dictate(h)

        #expect(h.local.openedConfigs.isEmpty)
        #expect(h.state.status == .error(OpenAIRealtimeEngine.keychainReadFailedReason))
        #expect(h.state.toastMessage == nil)
        #expect(h.llm.calls.isEmpty)
        #expect(h.inserter.calls.isEmpty)
        #expect(h.pipe.metrics.items.isEmpty)
    }

    @Test func an_on_device_engine_failure_does_not_fall_back() async {
        let otherOnDevice = EngineID.allCases.first { $0.isOnDevice && $0 != .onDeviceDefault }!
        let onDevice = FakeTranscriptionEngine(id: otherOnDevice, metricsID: "fake:on-device")
        let session = FakeTranscriptionSession()
        session.finishResult = .failure(Boom())
        onDevice.nextSessions = [session]
        let h = makeHarness(current: onDevice)
        await dictate(h)

        #expect(h.local.openedConfigs.isEmpty)
        #expect(h.state.status == .error(Self.transcriptionFailed))
    }

    // MARK: - Cancel

    @Test func cancel_during_the_fallback_returns_at_once_and_drops_its_result() async {
        let h = makeHarness()
        h.cloudSession.finishResult = .failure(Self.serverError("Internal server error"))
        h.localSession.holdFinish = true
        h.localSession.ignoresCancel = true
        defer { h.localSession.releaseFinish() }
        h.pipe.startRecording()
        let finalize = Task { await h.pipe.finalizeRecording() }
        #expect(await eventually { h.localSession.finishCount == 1 })
        #expect(h.state.status == .thinking)
        #expect(h.state.pipelinePhase == .transcribing)
        #expect(h.state.isCancellable)

        h.pipe.cancel()
        let localSession = h.localSession
        await awaitWhileHeld(finalize) { localSession.releaseFinish() }
        #expect(h.localSession.isHoldingFinish, "finalize returned while the on-device engine still held finish")
        #expect(h.state.status == .idle)
        #expect(h.state.toastMessage == "Cancelled")
        #expect(h.localSession.cancelCount == 1, "cancel reaches the on-device session")

        h.localSession.releaseFinish()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(h.llm.calls.isEmpty)
        #expect(h.inserter.calls.isEmpty)
        #expect(h.history.items.isEmpty)
        #expect(h.pipe.metrics.items.isEmpty)
        #expect(h.state.status == .idle)
        #expect(h.state.toastMessage == "Cancelled")
        #expect(h.state.lastTranscript == nil)
        #expect(h.state.retryTranscript == nil)
    }

    @Test func cancel_during_the_fallback_cancels_a_cooperative_session() async {
        let h = makeHarness()
        h.cloudSession.finishResult = .failure(Self.serverError("Internal server error"))
        h.localSession.holdFinish = true
        h.pipe.startRecording()
        let finalize = Task { await h.pipe.finalizeRecording() }
        #expect(await eventually { h.localSession.finishCount == 1 })

        h.pipe.cancel()
        let localSession = h.localSession
        await awaitWhileHeld(finalize) { localSession.releaseFinish() }
        try? await Task.sleep(for: .milliseconds(20))
        #expect(h.localSession.cancelCount == 1)
        #expect(h.state.status == .idle)
        #expect(h.state.toastMessage == "Cancelled")
        #expect(h.llm.calls.isEmpty)
    }
}
