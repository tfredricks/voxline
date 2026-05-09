import Foundation
import WhisperKit

/// Wraps WhisperKit. The active model can be pre-downloaded via prepareModel(),
/// pre-loaded via prewarm(), or lazy-loaded on first transcribe() call.
@MainActor
final class TranscriptionService {

    /// Active model. Changing this invalidates any loaded pipeline.
    var model: WhisperModel {
        didSet { whisperKit = nil; loadTask = nil }
    }

    private var whisperKit: WhisperKit?

    /// Dedupes concurrent loadIfNeeded() calls (e.g., a background prewarm
    /// racing against a user-triggered transcribe).
    private var loadTask: Task<WhisperKit, Error>?

    init(model: WhisperModel = .default) {
        self.model = model
    }

    /// True if the model variant for `model` is present in the standard
    /// Hub cache directory. Checked synchronously; safe to call on launch.
    static func isModelCached(_ model: WhisperModel) -> Bool {
        cachedModelFolder(for: model) != nil
    }

    /// Download the model if not already cached, reporting progress in [0, 1].
    /// Idempotent: returns immediately if the model is already cached.
    func prepareModel(progressHandler: @escaping @Sendable (Double) -> Void) async throws {
        if Self.isModelCached(model) { return }
        _ = try await WhisperKit.download(
            variant: model.whisperKitIdentifier,
            from: "argmaxinc/whisperkit-coreml"
        ) { progress in
            progressHandler(progress.fractionCompleted)
        }
    }

    /// Force-load the model into Core ML / Apple Neural Engine so the first
    /// transcribe() call doesn't pay the multi-second compile cost. Idempotent
    /// and dedupes against in-flight loads.
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
    /// directory if it exists and is non-empty, otherwise nil. The path is
    /// sandbox-aware via FileManager.documentDirectory.
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
        if let task = loadTask {
            return try await task.value
        }
        let variant = model.whisperKitIdentifier
        let task = Task<WhisperKit, Error> {
            // Use the standard config: WhisperKit checks cache first, skips
            // download if files are present, and resolves the tokenizer
            // (small file) via download as needed. Avoids modelFolder +
            // download:false combinations that block tokenizer fetch.
            let config = WhisperKitConfig(
                model: variant,
                modelRepo: "argmaxinc/whisperkit-coreml",
                verbose: false,
                logLevel: .error,
                prewarm: true,
                load: true,
                download: true
            )
            return try await WhisperKit(config)
        }
        loadTask = task
        do {
            let kit = try await task.value
            whisperKit = kit
            loadTask = nil
            return kit
        } catch {
            loadTask = nil
            throw error
        }
    }
}
