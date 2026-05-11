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
    func transcribe(samples: [Float]) async throws -> String
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
