import Foundation
import WhisperKit

/// Wraps WhisperKit. The active model can be pre-downloaded via prepareModel(),
/// or lazy-downloaded on first transcribe() call as a fallback.
@MainActor
final class TranscriptionService {

    /// Active model. Changing this invalidates any loaded pipeline and
    /// re-checks whether the new model is already cached on disk.
    var model: WhisperModel {
        didSet {
            whisperKit = nil
            modelFolder = Self.cachedModelFolder(for: model)
        }
    }

    private var whisperKit: WhisperKit?

    /// Filesystem URL where the model files live, once known to be cached.
    /// Set on init from disk, or by prepareModel() after a fresh download.
    private var modelFolder: URL?

    init(model: WhisperModel = .default) {
        self.model = model
        self.modelFolder = Self.cachedModelFolder(for: model)
    }

    /// True if the model variant for `model` is present in the standard
    /// Hub cache directory. Checked synchronously; safe to call on launch.
    static func isModelCached(_ model: WhisperModel) -> Bool {
        cachedModelFolder(for: model) != nil
    }

    /// Download the model if not already cached, reporting progress in [0, 1].
    /// Idempotent: returns immediately if the model is already cached.
    func prepareModel(progressHandler: @escaping @Sendable (Double) -> Void) async throws {
        if modelFolder != nil { return }
        let url = try await WhisperKit.download(
            variant: model.whisperKitIdentifier,
            from: "argmaxinc/whisperkit-coreml"
        ) { progress in
            progressHandler(progress.fractionCompleted)
        }
        modelFolder = url
    }

    /// Force-load the model into Core ML / Apple Neural Engine so the first
    /// transcribe() call doesn't pay the multi-second compile cost. Idempotent.
    func prewarm() async throws {
        _ = try await loadIfNeeded()
    }

    /// Transcribe a Float32 PCM buffer at AudioFormat.whisperSampleRate.
    func transcribe(samples: [Float]) async throws -> String {
        let kit = try await loadIfNeeded()
        let results = try await kit.transcribe(audioArray: samples)
        return results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Private

    /// Standard Hub cache layout used by huggingface-swift: returns the model
    /// directory if it exists and is non-empty, otherwise nil.
    private static func cachedModelFolder(for model: WhisperModel) -> URL? {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let path = docs
            .appendingPathComponent("huggingface", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("argmaxinc", isDirectory: true)
            .appendingPathComponent("whisperkit-coreml", isDirectory: true)
            .appendingPathComponent(model.whisperKitIdentifier, isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path.path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: path.path)) ?? []
        return contents.isEmpty ? nil : path
    }

    private func loadIfNeeded() async throws -> WhisperKit {
        if let kit = whisperKit { return kit }

        let config: WhisperKitConfig
        if let modelFolder {
            // Fast path: model is on disk, point WhisperKit at it directly.
            config = WhisperKitConfig(
                modelFolder: modelFolder.path,
                verbose: false,
                logLevel: .error,
                prewarm: true,
                load: true,
                download: false
            )
        } else {
            // Fallback: lazy download. prepareModel() should be preferred so
            // the user sees a progress UI instead of a silent stall.
            config = WhisperKitConfig(
                model: model.whisperKitIdentifier,
                modelRepo: "argmaxinc/whisperkit-coreml",
                verbose: false,
                logLevel: .error,
                prewarm: true,
                load: true,
                download: true
            )
        }

        let kit = try await WhisperKit(config)
        whisperKit = kit
        return kit
    }
}
