// voxline/Pipeline/PipelineProtocols.swift  (replace contents)
import AppKit
import Foundation

@MainActor
protocol AudioCapturing: AnyObject {
    var onLevel: ((Float) -> Void)? { get set }
    func start() throws
    func stop()
    func takeSamples() -> [Float]
}

@MainActor
protocol Transcribing: AnyObject {
    func transcribe(samples: [Float]) async throws -> String
}

protocol ModeResolving: Sendable {
    /// Returns the active mode given a frontmost-app bundle ID.
    /// Implemented by ModeRouter under the hood; the bundle-ID lookup is
    /// the testable seam.
    func mode(for bundleID: String?) -> Mode?
}

protocol LLMServing: Sendable {
    func cleanup(transcript: String, mode: Mode) async throws -> String
}

@MainActor
protocol ClipboardInjecting: AnyObject {
    func inject(_ text: String) async throws
}

protocol FrontmostAppProviding: Sendable {
    /// Bundle ID of whatever app holds keyboard focus right now, or nil if
    /// none could be resolved (no frontmost app, sandboxed lookup blocked).
    func frontmostBundleID() -> String?
}

extension AudioCaptureService: AudioCapturing {}
extension TranscriptionService: Transcribing {}
extension ModeRouter: ModeResolving {}
extension LLMService: LLMServing {}
extension ClipboardInjector: ClipboardInjecting {}
