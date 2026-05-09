import Foundation
import WhisperKit

/// Wraps WhisperKit. Lazy-loads the active model on first call; subsequent
/// calls reuse the loaded pipeline.
@MainActor
final class TranscriptionService {

    /// Active model. Changing this invalidates any loaded pipeline.
    var model: WhisperModel {
        didSet { whisperKit = nil }
    }

    /// Called with download progress in [0, 1] while the model is being fetched
    /// on first use. Set this before calling transcribe().
    var onModelDownloadProgress: ((Double) -> Void)?

    private var whisperKit: WhisperKit?

    init(model: WhisperModel = .default) {
        self.model = model
    }

    /// Transcribe a Float32 PCM buffer at AudioFormat.whisperSampleRate.
    func transcribe(samples: [Float]) async throws -> String {
        let kit = try await loadIfNeeded()
        let results = try await kit.transcribe(audioArray: samples)
        // WhisperKit returns [TranscriptionResult]; concatenate text segments.
        return results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Private

    private func loadIfNeeded() async throws -> WhisperKit {
        if let kit = whisperKit { return kit }

        // Configure WhisperKit to download/load the active model.
        let config = WhisperKitConfig(
            model: model.whisperKitIdentifier,
            modelRepo: "argmaxinc/whisperkit-coreml",
            verbose: false,
            logLevel: .error,
            prewarm: true,
            load: true,
            download: true
        )

        let kit = try await WhisperKit(config)
        whisperKit = kit
        return kit
    }
}
