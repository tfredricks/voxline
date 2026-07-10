import AppKit
import Foundation

@MainActor
protocol AudioCapturing: AnyObject {
    var onLevel: ((Float) -> Void)? { get set }
    var onTapCallback: ((Int) -> Void)? { get set }
    /// Best-effort: spin the audio engine up before the chord completes so
    /// start() captures from the first tap buffer. Must be cheap and safe
    /// to call repeatedly; errors are deferred to start().
    func prewarm()
    /// Tear down a prewarmed-but-unused engine (chord never completed, or
    /// recording was refused). Must be a no-op while a capture is running.
    func stopPrewarm()
    func start() throws
    func stop()
    func takeSamples() -> [Float]
}

@MainActor
protocol Transcribing: AnyObject {
    /// Transcribe a Float32 PCM buffer at AudioFormat.whisperSampleRate.
    /// Vocabulary biasing happens later in the pipeline via the LLM cleanup
    /// prompt — see `LLMService.transcriptionPreamble`.
    func transcribe(samples: [Float]) async throws -> String
}

protocol FocusedFieldInspecting: Sendable {
    /// Snapshot of the focused UI element at the moment of the call, or nil
    /// if no element is exposed (no Accessibility permission, custom view
    /// that doesn't publish role info, etc.). Callers fall back to bundle-
    /// ID-only routing when this returns nil.
    func inspect() -> FocusedField?
}

protocol LLMServing: Sendable {
    func cleanup(transcript: String, mode: Mode, context: CapturedContext) async throws -> String
}

@MainActor
protocol ClipboardInjecting: AnyObject {
    @discardableResult
    func inject(_ text: String) async throws -> TextInsertionOutcome
}

protocol FrontmostAppProviding: Sendable {
    /// Bundle ID of whatever app holds keyboard focus right now, or nil if
    /// none could be resolved (no frontmost app, sandboxed lookup blocked).
    func frontmostBundleID() -> String?
}

extension AudioCaptureService: AudioCapturing {}
extension TranscriptionService: Transcribing {}
extension ClipboardInjector: ClipboardInjecting {}
// LLMService: LLMServing lives in its own source file — Sendable-bearing
// protocol conformances must be declared in the same file as the type under
// Swift 6's strict concurrency rules.
