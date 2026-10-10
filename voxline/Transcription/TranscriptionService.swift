import Foundation
import WhisperKit

/// Errors thrown by transcription prep paths that warrant a tailored
/// user-facing message instead of the raw WhisperKit error.
enum TranscriptionPrepError: LocalizedError {
    case insufficientDiskSpace(model: WhisperModel, requiredMB: Int, availableMB: Int)

    var errorDescription: String? {
        switch self {
        case .insufficientDiskSpace(let model, let required, let available):
            return "Not enough disk space to download \(model.displayName). Need about \(required) MB free; only \(available) MB available. Free up space and try again."
        }
    }
}

/// Wraps WhisperKit. The active model can be pre-downloaded via prepareModel(),
/// pre-loaded via prewarm(), or lazy-loaded on first transcribe() call.
@MainActor
final class TranscriptionService {

    /// Active model. Changing this invalidates any loaded pipeline.
    var model: WhisperModel {
        didSet {
            // Cancel any in-flight load for the previous variant. Without
            // this, the orphan task could complete and assign its
            // wrong-variant WhisperKit into `whisperKit` — see the variant
            // check in loadIfNeeded for the matching guard on the consumer
            // side.
            unload()
        }
    }

    private var whisperKit: WhisperKit?

    var engineID: String { "whisperkit:\(model.whisperKitIdentifier)" }

    /// Reference-typed entry so identity comparisons (`===`) are ABA-safe:
    /// distinguishing "this is still my registration" from "a same-variant
    /// successor replaced me" cannot be done with the variant string alone.
    private final class LoadEntry {
        let variant: String
        let task: Task<WhisperKit, Error>
        init(variant: String, task: Task<WhisperKit, Error>) {
            self.variant = variant
            self.task = task
        }
    }

    /// Dedupes concurrent loadIfNeeded() calls (e.g., a background prewarm
    /// racing against a user-triggered transcribe). The entry's task identity
    /// is what the post-await tail compares against to decide whether it
    /// still owns the registration.
    private var loadTask: LoadEntry?

    init(model: WhisperModel = .default) {
        self.model = model
    }

    /// True if every file of the model variant for `model` is in the
    /// standard Hub cache directory; an interrupted download is not cached.
    /// Checked synchronously; safe to call on launch. Never creates the
    /// cache directory.
    static func isModelCached(_ model: WhisperModel) -> Bool {
        WhisperModelCache.cachedFolder(
            forVariant: model.whisperKitIdentifier,
            in: AppPaths.modelCacheDirectoryIfPresent()
        ) != nil
    }

    /// Headroom (MB) added to the raw model size when checking free space.
    /// Covers transient staging/extraction during download.
    private static let diskSpaceHeadroomMB = 500

    /// Throws `TranscriptionPrepError.insufficientDiskSpace` if the volume
    /// hosting the Hub cache can't fit the model plus a safety margin.
    /// Silently passes when capacity can't be read — the download itself
    /// will surface a clearer error if space truly runs out, and we don't
    /// want a filesystem-API edge case to block users.
    static func preflightDiskSpace(for model: WhisperModel) throws {
        let requiredMB = model.approxSizeMB + diskSpaceHeadroomMB
        let requiredBytes = Int64(requiredMB) * 1_048_576
        guard let cacheRoot = try? AppPaths.modelCacheDirectory() else { return }
        let values = try? cacheRoot.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values?.volumeAvailableCapacityForImportantUsage else {
            return
        }
        if available < requiredBytes {
            throw TranscriptionPrepError.insufficientDiskSpace(
                model: model,
                requiredMB: requiredMB,
                availableMB: Int(available / 1_048_576)
            )
        }
    }

    /// Download the model if not already cached, reporting progress in [0, 1].
    /// Idempotent: returns immediately if the model is already cached.
    func prepareModel(progressHandler: @escaping @Sendable (Double) -> Void) async throws {
        if Self.isModelCached(model) { return }
        try Self.preflightDiskSpace(for: model)
        let downloadBase = try AppPaths.modelCacheDirectory()
        _ = try await WhisperKit.download(
            variant: model.whisperKitIdentifier,
            downloadBase: downloadBase,
            from: WhisperModelCache.repo
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

    /// The loaded pipeline, loading it first if needed. Streaming sessions
    /// transcribe against it directly.
    func loadedKit() async throws -> WhisperKit { try await loadIfNeeded() }

    /// Releases the loaded pipeline and cancels any load in flight. Sessions
    /// already open keep their own reference; the next use loads it again.
    func unload() {
        loadTask?.task.cancel()
        loadTask = nil
        whisperKit = nil
    }

    /// Transcribe a Float32 PCM buffer at AudioFormat.whisperSampleRate.
    /// Returns the concatenated text across all decoded segments, trimmed.
    /// Vocabulary biasing is handled downstream by `LLMService` against the
    /// `CapturedContext.customVocabulary` line in the prompt.
    func transcribe(samples: [Float]) async throws -> String {
        let kit = try await loadIfNeeded()
        let results = try await kit.transcribe(audioArray: samples, decodeOptions: DecodingOptions())
        return results.map(\.text).joined(separator: " ").trimmed
    }

    // MARK: - Private

    private func loadIfNeeded() async throws -> WhisperKit {
        // Loop instead of recursing: each iteration represents one model
        // swap that happened mid-load. Bounded by user behavior (number of
        // sequential model swaps during a single load); explicit loop makes
        // the bound visible and avoids unbounded async recursion depth.
        while true {
            if let kit = whisperKit { return kit }
            let currentVariant = model.whisperKitIdentifier
            // Reuse the in-flight task only if it's loading the variant we
            // still want. A variant mismatch here means model.didSet ran
            // during the load — drop the stale task and start a fresh one.
            if let entry = loadTask, entry.variant == currentVariant {
                return try await entry.task.value
            }
            let variant = currentVariant
            let downloadBase = try AppPaths.modelCacheDirectory()
            let task = Task<WhisperKit, Error> {
                let config = WhisperModelCache.config(variant: variant, downloadBase: downloadBase, prewarm: true)
                let kit = try await WhisperKit(config)
                // WhisperKit's init doesn't reliably observe cancellation
                // mid-flight. Check explicitly so a cancelled load doesn't
                // race the next load to assign whisperKit.
                try Task.checkCancellation()
                return kit
            }
            let entry = LoadEntry(variant: variant, task: task)
            loadTask = entry
            let loadStart = Date()
            do {
                let kit = try await task.value
                // The model may have been swapped between Task creation and
                // now. Assigning the wrong-variant kit into `whisperKit`
                // would silently cause subsequent transcribes to run against
                // the previous model. If the variant moved on, loop and
                // start a fresh load for the new variant.
                guard variant == model.whisperKitIdentifier else {
                    // Only clear if we still own the registration; an ABA
                    // successor for the same variant would `===`-mismatch.
                    if loadTask === entry { loadTask = nil }
                    continue
                }
                whisperKit = kit
                if loadTask === entry { loadTask = nil }
                let loadDuration = Date().timeIntervalSince(loadStart)
                AppLog.whisper.info("model loaded: \(variant) (\(String(format: "%.1f", loadDuration))s)")
                return kit
            } catch {
                if loadTask === entry { loadTask = nil }
                throw error
            }
        }
    }
}

