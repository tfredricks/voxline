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
        let dir = base.appending(path: "voxline", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func modesFile() throws -> URL {
        try applicationSupportDirectory().appending(path: "modes.json")
    }

    /// Root WhisperKit downloads into. The Hub layout underneath is
    /// `models/argmaxinc/whisperkit-coreml/<variant>`.
    static func modelCacheDirectory() throws -> URL {
        let dir = try applicationSupportDirectory().appending(path: "huggingface", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Where sandboxed 0.3.x builds kept everything. Read only by `ContainerMigration`.
    static func legacyContainerDataDirectory(home: URL = .homeDirectory) -> URL {
        home.appending(path: "Library/Containers/\(bundleID)/Data", directoryHint: .isDirectory)
    }
}
