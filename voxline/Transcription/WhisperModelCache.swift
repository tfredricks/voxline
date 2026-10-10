import Foundation
import WhisperKit

/// Where a Whisper model lives in the Hub cache, whether all of it is there,
/// and how WhisperKit should load it.
enum WhisperModelCache {

    static let repo = "argmaxinc/whisperkit-coreml"

    /// The files that make each compiled model WhisperKit loads usable. The
    /// Hub moves a file into place only once it has finished downloading,
    /// in no fixed order, so an interrupted download leaves a non-empty
    /// folder with some of these missing.
    static let requiredFiles: [String] = ["MelSpectrogram", "AudioEncoder", "TextDecoder"].flatMap { model in
        ["\(model).mlmodelc/coremldata.bin", "\(model).mlmodelc/weights/weight.bin"]
    }

    static func folder(forVariant variant: String, in cacheBase: URL) -> URL {
        cacheBase
            .appending(path: "models", directoryHint: .isDirectory)
            .appending(path: repo, directoryHint: .isDirectory)
            .appending(path: variant, directoryHint: .isDirectory)
    }

    /// The variant's folder when every required file is present, else nil.
    static func cachedFolder(forVariant variant: String, in cacheBase: URL?) -> URL? {
        guard let cacheBase else { return nil }
        let folder = folder(forVariant: variant, in: cacheBase)
        return isComplete(folder) ? folder : nil
    }

    static func isComplete(_ folder: URL) -> Bool {
        requiredFiles.allSatisfy {
            FileManager.default.fileExists(atPath: folder.appending(path: $0).path)
        }
    }

    /// A cached model loads from its folder without touching the network:
    /// with no `modelFolder`, WhisperKit lists the repo on Hugging Face and
    /// checks every file before it reads the local copy, and fails offline.
    /// The tokenizer is read from `downloadBase` either way, and fetched
    /// only if it isn't there. A model that isn't cached is downloaded.
    static func config(
        variant: String,
        downloadBase: URL,
        cachedFolder: URL?,
        prewarm: Bool
    ) -> WhisperKitConfig {
        WhisperKitConfig(
            model: variant,
            downloadBase: downloadBase,
            modelRepo: repo,
            modelFolder: cachedFolder?.path,
            verbose: false,
            logLevel: .error,
            prewarm: prewarm,
            load: true,
            download: cachedFolder == nil
        )
    }

    /// The load config for `variant` given what is in the cache now.
    static func config(variant: String, downloadBase: URL, prewarm: Bool) -> WhisperKitConfig {
        config(
            variant: variant,
            downloadBase: downloadBase,
            cachedFolder: cachedFolder(forVariant: variant, in: downloadBase),
            prewarm: prewarm
        )
    }
}
