import Testing
import Foundation
@testable import voxline

@Suite @MainActor struct CapturePipelineErrorTaxonomyTests {

    // MARK: - Helpers

    private func pipeline(
        transcript: Result<String, Error> = .success("hello"),
        cleanup: @escaping (String, Mode, CapturedContext) async throws -> String = { t, _, _ in t },
        insert: InsertOutcome = .inserted(.paste, verified: false),
        modes: [Mode] = [Mode(bundleID: "*", displayName: "Default", prompt: "p", model: nil, temperature: nil)]
    ) -> (CapturePipeline, AppState, FakeCapture) {
        let state = AppState()
        let capture = FakeCapture()
        capture.pendingSamples = [Float](repeating: 0.5, count: 16_000)
        let engine = FakeTranscriptionEngine()
        let session = FakeTranscriptionSession()
        session.finishResult = transcript
        engine.nextSessions = [session]
        let inserter = FakeTextInserter()
        inserter.outcomes = [insert]
        let suiteName = "voxline-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let p = CapturePipeline(
            state: state,
            capture: capture,
            engines: FakeEngineProvider(engine),
            llm: FakeLLM(handler: cleanup),
            modes: ModeRouter(modes: modes),
            frontmost: FakeFrontmost(),
            fieldInspector: FakeFieldInspector(),
            inserter: inserter,
            historyStore: DictationHistoryStore(defaults: defaults),
            contextCapture: FakeContextCapture(),
            selectionSnapshot: FakeSelectionSnapshot(),
            llmModelID: { "test-model" },
            vocabulary: { [] },
            skipShortUtterances: { false },
            chords: { .default }
        )
        return (p, state, capture)
    }

    private func runOnce(_ p: CapturePipeline, _ state: AppState) async {
        p.startRecording()
        await p.finalizeRecording()
    }

    // MARK: - Tests

    @Test func missing_api_key_surfaces_actionable_error() async {
        let (p, state, _) = pipeline(cleanup: { _, _, _ in throw LLMError.missingAPIKey })
        p.transcriptFallback = { _ in } // avoid touching the real pasteboard in tests
        await runOnce(p, state)
        guard case .error(let msg) = state.status else {
            Issue.record("Expected .error status, got \(state.status)"); return
        }
        #expect(msg.contains("Settings → AI Provider"))
    }

    @Test func invalid_api_key_says_so() async {
        let (p, state, _) = pipeline(cleanup: { _, _, _ in throw LLMError.invalidAPIKey })
        p.transcriptFallback = { _ in } // avoid touching the real pasteboard in tests
        await runOnce(p, state)
        guard case .error(let msg) = state.status else { Issue.record("expected error"); return }
        #expect(msg.lowercased().contains("rejected"))
    }

    @Test func network_error_includes_network_word() async {
        struct NetErr: Error {}
        let (p, state, _) = pipeline(cleanup: { _, _, _ in throw LLMError.network(NetErr()) })
        p.transcriptFallback = { _ in } // avoid touching the real pasteboard in tests
        await runOnce(p, state)
        guard case .error(let msg) = state.status else { Issue.record("expected error"); return }
        #expect(msg.lowercased().contains("network"))
    }

    @Test func transcription_failure_surfaces_actionable_message() async {
        struct TranscribeFail: Error {}
        let (p, state, _) = pipeline(transcript: .failure(TranscribeFail()))
        await runOnce(p, state)
        guard case .error(let msg) = state.status else { Issue.record("expected error"); return }
        #expect(msg.lowercased().contains("transcription"))
    }

    @Test func text_insertion_failure_surfaces_actionable_message() async {
        let (p, state, _) = pipeline(insert: .failed(.allStrategiesFailed(["Typing produced no change"])))
        await runOnce(p, state)
        guard case .error(let msg) = state.status else { Issue.record("expected error"); return }
        #expect(msg == "Couldn't insert the text.")
    }

    @Test func missing_fallback_mode_points_at_the_modes_file() async {
        let (p, state, _) = pipeline(modes: [])
        await runOnce(p, state)
        guard case .error(let msg) = state.status else { Issue.record("expected error"); return }
        #expect(msg.contains("modes.json"))
        #expect(!msg.contains("Settings →"))
    }

    @Test func revoked_accessibility_during_paste_is_sticky_permissions_error() async {
        let (p, state, _) = pipeline(insert: .failed(.accessibilityNotGranted))
        await runOnce(p, state)
        guard case .permissionsError(let msg) = state.status else {
            Issue.record("Expected .permissionsError status, got \(state.status)"); return
        }
        #expect(msg.lowercased().contains("accessibility"))
    }

    @Test func error_path_clears_recording_state() async {
        let (p, state, _) = pipeline(cleanup: { _, _, _ in throw LLMError.missingAPIKey })
        p.transcriptFallback = { _ in } // avoid touching the real pasteboard in tests
        await runOnce(p, state)
        #expect(state.recordingStartedAt == nil)
        #expect(state.audioLevel == 0)
    }

    @Test func samples_with_zero_peak_surface_microphone_error() async {
        let state = AppState()
        let capture = FakeCapture()
        capture.pendingSamples = [Float](repeating: 0.0, count: 16_000) // 1 second of pure silence
        let suiteName = "voxline-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let p = CapturePipeline(
            state: state,
            capture: capture,
            engines: FakeEngineProvider(FakeTranscriptionEngine()),
            llm: FakeLLM(handler: { t, _, _ in t }),
            modes: ModeRouter(modes: [Mode(bundleID: "*", displayName: "D", prompt: "p", model: nil, temperature: nil)]),
            frontmost: FakeFrontmost(),
            fieldInspector: FakeFieldInspector(),
            inserter: FakeTextInserter(),
            historyStore: DictationHistoryStore(defaults: defaults),
            contextCapture: FakeContextCapture(),
            selectionSnapshot: FakeSelectionSnapshot(),
            llmModelID: { "test-model" },
            vocabulary: { [] },
            skipShortUtterances: { false },
            chords: { .default }
        )
        p.startRecording()
        await p.finalizeRecording()
        guard case .error(let msg) = state.status else {
            Issue.record("Expected .error, got \(state.status)"); return
        }
        #expect(msg.lowercased().contains("microphone"))
    }
}

// MARK: - Test fakes
//
// AudioCapturing is AnyObject-constrained
// (and @MainActor). LLMServing / FrontmostAppProviding are Sendable.

@MainActor
private final class FakeCapture: AudioCapturing {
    var pendingSamples: [Float] = [Float](repeating: 0.1, count: 8_000)
    var onLevel: ((Float) -> Void)?
    var onTapCallback: ((Int) -> Void)?
    var onSamples: (@Sendable ([Float]) -> Void)?
    var onInterrupted: (() -> Void)?
    func prewarm() {}
    func stopPrewarm() {}
    func start() throws {
        if !pendingSamples.isEmpty { onSamples?(pendingSamples) }
    }
    func stop() {}
}

private final class FakeLLM: LLMServing, @unchecked Sendable {
    let handler: (String, Mode, CapturedContext) async throws -> String
    init(handler: @escaping (String, Mode, CapturedContext) async throws -> String) { self.handler = handler }
    func cleanup(transcript: String, mode: Mode, context: CapturedContext) async throws -> String {
        try await handler(transcript, mode, context)
    }
    func command(_ request: CommandRequest) async throws -> CommandResult {
        CommandResult(action: .insert, text: "")
    }
}

private struct FakeFrontmost: FrontmostAppProviding {
    func frontmostBundleID() -> String? { "com.example.app" }
}

private struct FakeFieldInspector: FocusedFieldInspecting {
    func inspect() -> FocusedField? { nil }
}

/// Always "no selection" so these dictation-error-taxonomy tests take the
/// dictation path (and never post a real synthetic Cmd+C via the default).
private struct FakeSelectionSnapshot: SelectionSnapshotting {
    func readSelection() async -> String? { nil }
}
