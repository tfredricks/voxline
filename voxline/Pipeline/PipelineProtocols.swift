import Foundation

/// Testability seam for AudioCaptureService.
@MainActor
protocol AudioCapturing: AnyObject {
    var onLevel: ((Float) -> Void)? { get set }
    func start() throws
    func stop()
    func takeSamples() -> [Float]
}

/// Testability seam for TranscriptionService.
@MainActor
protocol Transcribing: AnyObject {
    func transcribe(samples: [Float]) async throws -> String
}

extension AudioCaptureService: AudioCapturing {}
extension TranscriptionService: Transcribing {}
