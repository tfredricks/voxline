import Foundation

/// Every on-disk location the app owns. Nothing else builds paths.
enum AppPaths {

    static let bundleID = "com.voxline.app"

    static func applicationSupportDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = appDirectory(in: base)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func modesFile() throws -> URL {
        try applicationSupportDirectory().appending(path: "modes.json")
    }

    /// Root WhisperKit downloads into. The Hub layout underneath is
    /// `models/argmaxinc/whisperkit-coreml/<variant>`.
    static func modelCacheDirectory() throws -> URL {
        let dir = modelCacheDirectory(inAppDirectory: try applicationSupportDirectory())
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Bake-off clips: where `BakeoffClipWriter` saves them and the bake-off
    /// reads them by default.
    static func bakeoffDirectory() throws -> URL {
        let dir = try applicationSupportDirectory().appending(path: "bakeoff", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The model cache root if it already exists; nil otherwise. Never
    /// creates a directory, so cache checks leave the disk untouched.
    static func modelCacheDirectoryIfPresent() -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return modelCacheDirectoryIfPresent(base: base)
    }

    /// `base` stands in for `~/Library/Application Support`.
    static func modelCacheDirectoryIfPresent(base: URL) -> URL? {
        let dir = modelCacheDirectory(inAppDirectory: appDirectory(in: base))
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return dir
    }

    private static func appDirectory(in applicationSupport: URL) -> URL {
        applicationSupport.appending(path: "voxline", directoryHint: .isDirectory)
    }

    private static func modelCacheDirectory(inAppDirectory appDirectory: URL) -> URL {
        appDirectory.appending(path: "huggingface", directoryHint: .isDirectory)
    }

    /// Where sandboxed 0.3.x builds kept everything. Read only by `ContainerMigration`.
    static func legacyContainerDataDirectory(home: URL = .homeDirectory) -> URL {
        home.appending(path: "Library/Containers/\(bundleID)/Data", directoryHint: .isDirectory)
    }
}
