import Foundation
import WhisperKit

/// Errors thrown by transcription prep paths that warrant a tailored
/// user-facing message instead of the raw WhisperKit error.
enum TranscriptionPrepError: LocalizedError {
    case insufficientDiskSpace(model: WhisperModel, requiredMB: Int, availableMB: Int)
    case tokenizerUnavailable

    var errorDescription: String? {
        switch self {
        case .insufficientDiskSpace(let model, let required, let available):
            return "Not enough disk space to download \(model.displayName). Need about \(required) MB free; only \(available) MB available. Free up space and try again."
        case .tokenizerUnavailable:
            return "The Whisper tokenizer is not available. The model may not have finished loading."
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
            loadTask?.task.cancel()
            loadTask = nil
            whisperKit = nil
        }
    }

    private var whisperKit: WhisperKit?

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

    /// True if the model variant for `model` is present in the standard
    /// Hub cache directory. Checked synchronously; safe to call on launch.
    static func isModelCached(_ model: WhisperModel) -> Bool {
        cachedModelFolder(for: model) != nil
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
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return
        }
        let values = try? docs.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
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
    /// When `vocabulary` is non-empty, builds promptTokens via
    /// `WhisperPromptBuilder` and passes them through DecodingOptions to
    /// bias the decoder toward those terms. Empty input → omit promptTokens
    /// entirely (WhisperKit treats `[]` differently from `nil`).
    ///
    /// Options when vocab is active:
    /// - `skipSpecialTokens: true` so the prefix prompt doesn't echo into
    ///   the output (matches WhisperKit's `testPromptTokens` reference).
    /// - `firstTokenLogProbThreshold: nil` because the vocab prompt biases
    ///   the decoder, the first generated token's logprob against the
    ///   actual audio falls below the default -1.5 threshold, fallback
    ///   trips on every retry, and the final result is empty.
    /// - `noSpeechThreshold: nil` for the same reason at the *segment*
    ///   level: the vocab prompt pushes the model's no-speech probability
    ///   above the default 0.6, the segment is declared "silence" with
    ///   no fallback, and an empty segment is returned. Observed in the
    ///   field: 2.2-second clips with actual speech were being classified
    ///   as silence whenever any vocab term was present.
    func transcribe(samples: [Float], vocabulary: [String] = []) async throws -> String {
        let kit = try await loadIfNeeded()
        let tokens: [Int]
        if vocabulary.isEmpty {
            tokens = []
        } else if let tokenizer = kit.tokenizer {
            tokens = WhisperPromptBuilder.promptTokens(from: vocabulary, tokenizer: tokenizer.asVocabularyTokenizing)
        } else {
            tokens = []
        }
        let options: DecodingOptions
        if tokens.isEmpty {
            options = DecodingOptions()
        } else {
            print("[voxline:whisper] vocab prompt: \(tokens.count) tokens, ids=\(tokens.prefix(20))")
            options = DecodingOptions(
                skipSpecialTokens: true,
                promptTokens: tokens,
                firstTokenLogProbThreshold: nil,
                noSpeechThreshold: nil
            )
        }
        let results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
        let joined = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if !tokens.isEmpty {
            print("[voxline:whisper] vocab transcribe result: chars=\(joined.count) text=\"\(joined)\" segments=\(results.count)")
            for (i, r) in results.enumerated() {
                print("[voxline:whisper] segment[\(i)] text=\"\(r.text)\"")
            }
        }
        return joined
    }

    /// Count tokens that `terms` would contribute when fed to Whisper. Loads
    /// the model if needed so the count matches reality. Used by the Settings
    /// vocabulary UI to render `N / 200 tokens` and to gate the Add button.
    func tokenCount(for terms: [String]) async throws -> Int {
        guard !terms.isEmpty else { return 0 }
        let kit = try await loadIfNeeded()
        guard let tokenizer = kit.tokenizer else {
            throw TranscriptionPrepError.tokenizerUnavailable
        }
        return WhisperPromptBuilder.tokenCount(of: terms, tokenizer: tokenizer.asVocabularyTokenizing)
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
            let task = Task<WhisperKit, Error> {
                // Use the standard config: WhisperKit checks cache first,
                // skips download if files are present, and resolves the
                // tokenizer (small file) via download as needed. Avoids
                // modelFolder + download:false combinations that block
                // tokenizer fetch.
                let config = WhisperKitConfig(
                    model: variant,
                    modelRepo: "argmaxinc/whisperkit-coreml",
                    verbose: false,
                    logLevel: .error,
                    prewarm: true,
                    load: true,
                    download: true
                )
                let kit = try await WhisperKit(config)
                // WhisperKit's init doesn't reliably observe cancellation
                // mid-flight. Check explicitly so a cancelled load doesn't
                // race the next load to assign whisperKit.
                try Task.checkCancellation()
                return kit
            }
            let entry = LoadEntry(variant: variant, task: task)
            loadTask = entry
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
                return kit
            } catch {
                if loadTask === entry { loadTask = nil }
                throw error
            }
        }
    }
}

/// Bridge: lifts the existential `WhisperTokenizer` to the local
/// `VocabularyTokenizing` protocol so the builder can consume it. We
/// can't add this in WhisperPromptBuilder.swift directly because
/// retroactive conformance of an imported protocol is restricted under
/// Swift 6; this file-private adapter sidesteps that. The struct lives
/// at file scope (rather than nested inside the extension getter) because
/// types declared inside a protocol-extension member sit in a generic
/// context and can't have synthesized initializers.
private struct WhisperTokenizerVocabularyAdapter: VocabularyTokenizing {
    let underlying: WhisperTokenizer
    var specialTokenBegin: Int { underlying.specialTokens.specialTokenBegin }
    func encode(text: String) -> [Int] { underlying.encode(text: text) }
}

private extension WhisperTokenizer {
    var asVocabularyTokenizing: VocabularyTokenizing {
        WhisperTokenizerVocabularyAdapter(underlying: self)
    }
}
