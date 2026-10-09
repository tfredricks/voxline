import Foundation

/// One-shot move of app data out of the 0.3.x sandbox container. Runs before
/// anything reads `UserDefaults`, the modes file, or the model cache. Never
/// overwrites a destination that already exists, and marks itself complete
/// even when a step fails so a broken container can't block every launch.
struct ContainerMigration {

    static let completedKey = "voxline.migration.containerMigrated"

    struct Report: Equatable {
        var preferencesCopied = 0
        var movedModes = false
        var movedModelCache = false
        var movedANECache = false
        var failures: [String] = []
    }

    let legacyDataDirectory: URL
    let applicationSupportDirectory: URL
    let cachesDirectory: URL
    let defaults: UserDefaults
    let fileManager: FileManager

    init(
        legacyDataDirectory: URL = AppPaths.legacyContainerDataDirectory(),
        applicationSupportDirectory: URL,
        cachesDirectory: URL,
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) {
        self.legacyDataDirectory = legacyDataDirectory
        self.applicationSupportDirectory = applicationSupportDirectory
        self.cachesDirectory = cachesDirectory
        self.defaults = defaults
        self.fileManager = fileManager
    }

    /// Production instance. Nil only when Application Support itself is unavailable.
    static func standard() -> ContainerMigration? {
        guard let appSupport = try? AppPaths.applicationSupportDirectory(),
              let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        return ContainerMigration(applicationSupportDirectory: appSupport, cachesDirectory: caches)
    }

    /// Nil when there was nothing to do: already migrated, or no container on disk.
    @discardableResult
    func runIfNeeded() -> Report? {
        guard !defaults.bool(forKey: Self.completedKey) else { return nil }
        guard fileManager.fileExists(atPath: legacyDataDirectory.path) else {
            defaults.set(true, forKey: Self.completedKey)
            return nil
        }

        var report = Report()
        copyPreferences(into: &report)
        move(
            legacyDataDirectory.appending(path: "Library/Application Support/voxline/modes.json"),
            to: applicationSupportDirectory.appending(path: "modes.json"),
            flag: \.movedModes, report: &report
        )
        move(
            legacyDataDirectory.appending(path: "Documents/huggingface", directoryHint: .isDirectory),
            to: applicationSupportDirectory.appending(path: "huggingface", directoryHint: .isDirectory),
            flag: \.movedModelCache, report: &report
        )
        move(
            legacyDataDirectory.appending(path: "Library/Caches/\(AppPaths.bundleID)/com.apple.e5rt.e5bundlecache", directoryHint: .isDirectory),
            to: cachesDirectory.appending(path: "\(AppPaths.bundleID)/com.apple.e5rt.e5bundlecache", directoryHint: .isDirectory),
            flag: \.movedANECache, report: &report
        )
        defaults.set(true, forKey: Self.completedKey)
        return report
    }

    private func copyPreferences(into report: inout Report) {
        let plist = legacyDataDirectory.appending(path: "Library/Preferences/\(AppPaths.bundleID).plist")
        guard fileManager.fileExists(atPath: plist.path) else { return }
        guard let dict = NSDictionary(contentsOf: plist) as? [String: Any] else {
            report.failures.append("preferences: unreadable plist")
            return
        }
        for (key, value) in dict where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
            report.preferencesCopied += 1
        }
    }

    private func move(_ source: URL, to destination: URL, flag: WritableKeyPath<Report, Bool>, report: inout Report) {
        guard fileManager.fileExists(atPath: source.path) else { return }
        guard !fileManager.fileExists(atPath: destination.path) else { return }
        do {
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.moveItem(at: source, to: destination)
            report[keyPath: flag] = true
        } catch {
            report.failures.append("\(source.lastPathComponent): \(error.localizedDescription)")
        }
    }
}
