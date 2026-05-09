import Testing
import Foundation
@testable import voxline

@Suite @MainActor struct CapturePipelineErrorTaxonomyTests {

    // MARK: - Helpers

    private func pipeline(
        transcribe: @escaping ([Float]) async throws -> String = { _ in "hello" },
        cleanup: @escaping (String, Mode) async throws -> String = { t, _ in t },
        inject: @escaping (String) async throws -> Void = { _ in }
    ) -> (CapturePipeline, AppState, FakeCapture) {
        let state = AppState()
        let capture = FakeCapture()
        capture.canned = [Float](repeating: 0.5, count: 16_000)
        let p = CapturePipeline(
            state: state,
            capture: capture,
            transcriber: FakeTranscriber(handler: transcribe),
            llm: FakeLLM(handler: cleanup),
            modes: ModeRouter(modes: [Mode(bundleID: "*", displayName: "Default", prompt: "p", model: nil, temperature: nil)]),
            frontmost: FakeFrontmost(),
            injector: FakeInjector(handler: inject)
        )
        return (p, state, capture)
    }

    private func runOnce(_ p: CapturePipeline) async {
        p.startRecording()
        await p.finalizeRecording()
    }

    // MARK: - Tests

    @Test func missing_api_key_surfaces_actionable_error() async {
        let (p, state, _) = pipeline(cleanup: { _, _ in throw LLMError.missingAPIKey })
        await runOnce(p)
        guard case .error(let msg) = state.status else {
            Issue.record("Expected .error status, got \(state.status)"); return
        }
        #expect(msg.contains("Settings → API Keys"))
    }

    @Test func invalid_api_key_says_so() async {
        let (p, state, _) = pipeline(cleanup: { _, _ in throw LLMError.invalidAPIKey })
        await runOnce(p)
        guard case .error(let msg) = state.status else { Issue.record("expected error"); return }
        #expect(msg.lowercased().contains("rejected"))
    }

    @Test func network_error_includes_network_word() async {
        struct NetErr: Error {}
        let (p, state, _) = pipeline(cleanup: { _, _ in throw LLMError.network(NetErr()) })
        await runOnce(p)
        guard case .error(let msg) = state.status else { Issue.record("expected error"); return }
        #expect(msg.lowercased().contains("network"))
    }

    @Test func transcription_failure_surfaces_actionable_message() async {
        struct TranscribeFail: Error {}
        let (p, state, _) = pipeline(transcribe: { _ in throw TranscribeFail() })
        await runOnce(p)
        guard case .error(let msg) = state.status else { Issue.record("expected error"); return }
        #expect(msg.lowercased().contains("transcription"))
    }

    @Test func paste_failure_surfaces_actionable_message() async {
        struct PasteFail: Error {}
        let (p, state, _) = pipeline(inject: { _ in throw PasteFail() })
        await runOnce(p)
        guard case .error(let msg) = state.status else { Issue.record("expected error"); return }
        #expect(msg.lowercased().contains("paste"))
    }

    @Test func error_path_clears_recording_state() async {
        let (p, state, _) = pipeline(cleanup: { _, _ in throw LLMError.missingAPIKey })
        await runOnce(p)
        #expect(state.recordingStartedAt == nil)
        #expect(state.audioLevel == 0)
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
    func start() throws {}
    func stop() {}
    func takeSamples() -> [Float] { defer { canned = [] }; return canned }
}

@MainActor
private final class FakeTranscriber: Transcribing {
    let handler: ([Float]) async throws -> String
    init(handler: @escaping ([Float]) async throws -> String) { self.handler = handler }
    func transcribe(samples: [Float]) async throws -> String { try await handler(samples) }
}

private final class FakeLLM: LLMServing, @unchecked Sendable {
    let handler: (String, Mode) async throws -> String
    init(handler: @escaping (String, Mode) async throws -> String) { self.handler = handler }
    func cleanup(transcript: String, mode: Mode) async throws -> String {
        try await handler(transcript, mode)
    }
}

private struct FakeFrontmost: FrontmostAppProviding {
    func frontmostBundleID() -> String? { "com.example.app" }
}

@MainActor
private final class FakeInjector: ClipboardInjecting {
    let handler: (String) async throws -> Void
    init(handler: @escaping (String) async throws -> Void) { self.handler = handler }
    func inject(_ text: String) async throws { try await handler(text) }
}
