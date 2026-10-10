import Foundation
import Testing
@testable import voxline

@Suite struct WhisperModelCacheTests {

    private static let variant = WhisperModel.largeV3Turbo.whisperKitIdentifier

    private func makeCacheBase() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "voxline-model-cache-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func write(_ files: [String], in folder: URL) throws {
        for file in files {
            let url = folder.appending(path: file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([0]).write(to: url)
        }
    }

    @Test func the_folder_follows_the_hub_cache_layout() {
        let base = URL(filePath: "/cache", directoryHint: .isDirectory)
        let folder = WhisperModelCache.folder(forVariant: Self.variant, in: base)
        #expect(folder.path == "/cache/models/argmaxinc/whisperkit-coreml/\(Self.variant)")
    }

    @Test func requires_the_compiled_manifest_and_weights_of_all_three_models() {
        #expect(Set(WhisperModelCache.requiredFiles) == [
            "MelSpectrogram.mlmodelc/coremldata.bin", "MelSpectrogram.mlmodelc/weights/weight.bin",
            "AudioEncoder.mlmodelc/coremldata.bin", "AudioEncoder.mlmodelc/weights/weight.bin",
            "TextDecoder.mlmodelc/coremldata.bin", "TextDecoder.mlmodelc/weights/weight.bin",
        ])
    }

    @Test func a_complete_folder_is_cached() throws {
        let base = try makeCacheBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = WhisperModelCache.folder(forVariant: Self.variant, in: base)
        try write(WhisperModelCache.requiredFiles + ["config.json"], in: folder)

        #expect(WhisperModelCache.cachedFolder(forVariant: Self.variant, in: base) == folder)
    }

    @Test(arguments: WhisperModelCache.requiredFiles)
    func an_interrupted_download_is_not_cached(missing: String) throws {
        let base = try makeCacheBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = WhisperModelCache.folder(forVariant: Self.variant, in: base)
        try write(WhisperModelCache.requiredFiles.filter { $0 != missing } + ["config.json"], in: folder)

        #expect(WhisperModelCache.cachedFolder(forVariant: Self.variant, in: base) == nil)
    }

    @Test func a_missing_folder_or_cache_is_not_cached() throws {
        let base = try makeCacheBase()
        defer { try? FileManager.default.removeItem(at: base) }

        #expect(WhisperModelCache.cachedFolder(forVariant: Self.variant, in: base) == nil)
        #expect(WhisperModelCache.cachedFolder(forVariant: Self.variant, in: nil) == nil)
    }

    @Test func a_cached_model_loads_from_its_folder_without_downloading() {
        let base = URL(filePath: "/cache", directoryHint: .isDirectory)
        let folder = WhisperModelCache.folder(forVariant: Self.variant, in: base)
        let config = WhisperModelCache.config(variant: Self.variant, downloadBase: base, cachedFolder: folder, prewarm: true)

        #expect(config.download == false)
        #expect(config.modelFolder == folder.path)
        #expect(config.downloadBase == base, "the tokenizer is read from the download base")
        #expect(config.model == Self.variant)
        #expect(config.load == true)
        #expect(config.prewarm == true)
    }

    @Test func a_model_that_is_not_cached_is_downloaded() {
        let base = URL(filePath: "/cache", directoryHint: .isDirectory)
        let config = WhisperModelCache.config(variant: Self.variant, downloadBase: base, cachedFolder: nil, prewarm: false)

        #expect(config.download == true)
        #expect(config.modelFolder == nil)
        #expect(config.downloadBase == base)
        #expect(config.modelRepo == "argmaxinc/whisperkit-coreml")
        #expect(config.load == true)
        #expect(config.prewarm == false)
    }

    @Test func the_cache_check_picks_the_config() throws {
        let base = try makeCacheBase()
        defer { try? FileManager.default.removeItem(at: base) }
        #expect(WhisperModelCache.config(variant: Self.variant, downloadBase: base, prewarm: false).download == true)

        let folder = WhisperModelCache.folder(forVariant: Self.variant, in: base)
        try write(WhisperModelCache.requiredFiles, in: folder)
        let cached = WhisperModelCache.config(variant: Self.variant, downloadBase: base, prewarm: false)
        #expect(cached.download == false)
        #expect(cached.modelFolder == folder.path)
    }
}
