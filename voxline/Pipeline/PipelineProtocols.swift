import AppKit
import Foundation

@MainActor
protocol AudioCapturing: AnyObject {
    var onLevel: ((Float) -> Void)? { get set }
    var onTapCallback: ((Int) -> Void)? { get set }
    func start() throws
    func stop()
    func takeSamples() -> [Float]
}

@MainActor
protocol Transcribing: AnyObject {
    /// Transcribe a Float32 PCM buffer at AudioFormat.whisperSampleRate.
    /// `vocabulary` is a list of canonical terms used to bias the Whisper
    /// decoder via `DecodingOptions.promptTokens`. Pass an empty array to
    /// disable biasing.
    func transcribe(samples: [Float], vocabulary: [String]) async throws -> String

    /// Live token count of `terms` against the active Whisper model's
    /// tokenizer. Used by the Settings UI to show budget headroom. Throws
    /// if the tokenizer cannot be obtained (model load failed).
    func tokenCount(for terms: [String]) async throws -> Int
}

protocol ModeResolving: Sendable {
    /// Returns the active mode given a frontmost-app bundle ID and an
    /// optional focused-field snapshot. Implemented by ModeRouter under the
    /// hood; the lookup is the testable seam.
    func mode(for bundleID: String?, field: FocusedField?) -> Mode?
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
// ModeRouter: ModeResolving and LLMService: LLMServing live in their own
// source files — Sendable-bearing protocol conformances must be declared in
// the same file as the type under Swift 6's strict concurrency rules.
