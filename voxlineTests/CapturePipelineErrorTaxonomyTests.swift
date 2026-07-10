import Testing
import Foundation
@testable import voxline

@Suite @MainActor struct CapturePipelineErrorTaxonomyTests {

    // MARK: - Helpers

    private func pipeline(
        transcribe: @escaping ([Float]) async throws -> String = { _ in "hello" },
        cleanup: @escaping (String, Mode, CapturedContext) async throws -> String = { t, _, _ in t },
        inject: @escaping (String) async throws -> TextInsertionOutcome = { _ in
            TextInsertionOutcome(strategy: .clipboardPaste, verification: .unverified)
        }
    ) -> (CapturePipeline, AppState, FakeCapture) {
        let state = AppState()
        let capture = FakeCapture()
        capture.canned = [Float](repeating: 0.5, count: 16_000)
        let suiteName = "voxline-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let p = CapturePipeline(
            state: state,
            capture: capture,
            transcriber: FakeTranscriber(handler: transcribe),
            llm: FakeLLM(handler: cleanup),
            modes: ModeRouter(modes: [Mode(bundleID: "*", displayName: "Default", prompt: "p", model: nil, temperature: nil)]),
            frontmost: FakeFrontmost(),
            fieldInspector: FakeFieldInspector(),
            injector: FakeInjector(handler: inject),
            historyStore: DictationHistoryStore(defaults: defaults),
            contextCapture: FakeContextCapture(),
            selectionSnapshot: FakeSelectionSnapshot()
        )
        return (p, state, capture)
    }

    private func runOnce(_ p: CapturePipeline, _ state: AppState) async {
        p.startRecording()
        state.lastPeakLevel = 0.5  // simulate the production onLevel callback firing
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
        #expect(msg.contains("Settings → API Keys"))
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
        let (p, state, _) = pipeline(transcribe: { _ in throw TranscribeFail() })
        await runOnce(p, state)
        guard case .error(let msg) = state.status else { Issue.record("expected error"); return }
        #expect(msg.lowercased().contains("transcription"))
    }

    @Test func text_insertion_failure_surfaces_actionable_message() async {
        struct PasteFail: Error {}
        let (p, state, _) = pipeline(inject: { _ in throw PasteFail() })
        await runOnce(p, state)
        guard case .error(let msg) = state.status else { Issue.record("expected error"); return }
        #expect(msg.lowercased().contains("text insertion"))
    }

    @Test func revoked_accessibility_during_paste_is_sticky_permissions_error() async {
        let (p, state, _) = pipeline(inject: { _ in throw TextInsertionError.accessibilityNotGranted })
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
        capture.canned = [Float](repeating: 0.0, count: 16_000) // 1 second of pure silence
        let suiteName = "voxline-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let p = CapturePipeline(
            state: state,
            capture: capture,
            transcriber: FakeTranscriber(handler: { _ in "" }),
            llm: FakeLLM(handler: { t, _, _ in t }),
            modes: ModeRouter(modes: [Mode(bundleID: "*", displayName: "D", prompt: "p", model: nil, temperature: nil)]),
            frontmost: FakeFrontmost(),
            fieldInspector: FakeFieldInspector(),
            injector: FakeInjector(handler: { _ in TextInsertionOutcome(strategy: .clipboardPaste, verification: .unverified) }),
            historyStore: DictationHistoryStore(defaults: defaults),
            contextCapture: FakeContextCapture(),
            selectionSnapshot: FakeSelectionSnapshot()
        )
        p.startRecording()
        // Do NOT set lastPeakLevel above 0 — simulating a silent mic where the
        // onLevel callback never gets a non-zero value.
        state.lastPeakLevel = 0
        await p.finalizeRecording()
        guard case .error(let msg) = state.status else {
            Issue.record("Expected .error, got \(state.status)"); return
        }
        #expect(msg.lowercased().contains("microphone"))
    }
}

// MARK: - Test fakes
//
// AudioCapturing / Transcribing / ClipboardInjecting are AnyObject-constrained
// (and @MainActor). LLMServing / FrontmostAppProviding are Sendable.

@MainActor
private final class FakeCapture: AudioCapturing {
    var canned: [Float] = []
    var onLevel: ((Float) -> Void)?
    var onTapCallback: ((Int) -> Void)?
    func prewarm() {}
    func stopPrewarm() {}
    func start() throws {}
    func stop() {}
    func takeSamples() -> [Float] { defer { canned = [] }; return canned }
}

@MainActor
private final class FakeTranscriber: Transcribing {
    let handler: ([Float]) async throws -> String
    init(handler: @escaping ([Float]) async throws -> String) { self.handler = handler }
    func transcribe(samples: [Float]) async throws -> String {
        try await handler(samples)
    }
}

private final class FakeLLM: LLMServing, @unchecked Sendable {
    let handler: (String, Mode, CapturedContext) async throws -> String
    init(handler: @escaping (String, Mode, CapturedContext) async throws -> String) { self.handler = handler }
    func cleanup(transcript: String, mode: Mode, context: CapturedContext, refinement: RefinementDirective?) async throws -> String {
        try await handler(transcript, mode, context)
    }
    func transform(instruction: String, selection: String, mode: Mode) async throws -> String {
        selection
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

@MainActor
private final class FakeInjector: ClipboardInjecting {
    let handler: (String) async throws -> TextInsertionOutcome
    init(handler: @escaping (String) async throws -> TextInsertionOutcome) { self.handler = handler }
    func inject(_ text: String) async throws -> TextInsertionOutcome { try await handler(text) }
    func replace(_ old: String, with new: String) async -> ReplaceOutcome { .fallbackClipboard }
}
