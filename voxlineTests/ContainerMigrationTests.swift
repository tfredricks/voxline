import Testing
import Foundation
@testable import voxline

@Suite struct ContainerMigrationTests {

    private struct Fixture {
        let root: URL
        let legacy: URL
        let appSupport: URL
        let caches: URL
        let defaults: UserDefaults
        let suiteName: String

        func tearDown() {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "voxline-migration-\(UUID().uuidString)", directoryHint: .isDirectory)
        let legacy = root.appending(path: "Containers/com.voxline.app/Data", directoryHint: .isDirectory)
        let appSupport = root.appending(path: "Application Support/voxline", directoryHint: .isDirectory)
        let caches = root.appending(path: "Caches", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        let suiteName = "voxline-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return Fixture(root: root, legacy: legacy, appSupport: appSupport, caches: caches, defaults: defaults, suiteName: suiteName)
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func legacyPrefsPlist(_ f: Fixture) -> URL {
        f.legacy.appending(path: "Library/Preferences/com.voxline.app.plist")
    }

    private func populateLegacy(_ f: Fixture) throws {
        let prefs: [String: Any] = ["voxline.whisper.model": "smallEn", "voxline.firstRun.completed": true]
        let plist = legacyPrefsPlist(f)
        try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        #expect((prefs as NSDictionary).write(to: plist, atomically: true))
        try write("[]", to: f.legacy.appending(path: "Library/Application Support/voxline/modes.json"))
        try write("weights", to: f.legacy.appending(path: "Documents/huggingface/models/argmaxinc/whisperkit-coreml/openai_whisper-small.en/model.bin"))
        try write("ane", to: f.legacy.appending(path: "Library/Caches/com.voxline.app/com.apple.e5rt.e5bundlecache/blob"))
    }

    private func migration(_ f: Fixture) -> ContainerMigration {
        ContainerMigration(
            legacyDataDirectory: f.legacy,
            applicationSupportDirectory: f.appSupport,
            cachesDirectory: f.caches,
            defaults: f.defaults
        )
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    @Test func moves_files_and_copies_preferences_exactly_once() throws {
        let f = try makeFixture()
        defer { f.tearDown() }
        try populateLegacy(f)

        let report = try #require(migration(f).runIfNeeded())

        #expect(report.movedModes)
        #expect(report.movedModelCache)
        #expect(report.movedANECache)
        #expect(report.preferencesCopied == 2)
        #expect(report.failures.isEmpty)
        #expect(exists(f.appSupport.appending(path: "modes.json")))
        #expect(exists(f.appSupport.appending(path: "huggingface/models/argmaxinc/whisperkit-coreml/openai_whisper-small.en/model.bin")))
        #expect(exists(f.caches.appending(path: "com.voxline.app/com.apple.e5rt.e5bundlecache/blob")))
        #expect(!exists(f.legacy.appending(path: "Documents/huggingface")))
        #expect(f.defaults.string(forKey: "voxline.whisper.model") == "smallEn")
        #expect(f.defaults.bool(forKey: "voxline.firstRun.completed"))
        #expect(f.defaults.bool(forKey: ContainerMigration.completedKey))
        #expect(migration(f).runIfNeeded() == nil)
    }

    @Test func missing_container_marks_complete_and_returns_nil() throws {
        let f = try makeFixture()
        defer { f.tearDown() }

        #expect(migration(f).runIfNeeded() == nil)
        #expect(f.defaults.bool(forKey: ContainerMigration.completedKey))
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.appSupport.path).isEmpty)
    }

    @Test func never_overwrites_existing_destinations_or_defaults() throws {
        let f = try makeFixture()
        defer { f.tearDown() }
        try populateLegacy(f)
        try write("existing", to: f.appSupport.appending(path: "modes.json"))
        f.defaults.set("largeV3Turbo", forKey: "voxline.whisper.model")

        let report = try #require(migration(f).runIfNeeded())

        #expect(!report.movedModes)
        #expect(try String(contentsOf: f.appSupport.appending(path: "modes.json"), encoding: .utf8) == "existing")
        #expect(exists(f.legacy.appending(path: "Library/Application Support/voxline/modes.json")))
        #expect(f.defaults.string(forKey: "voxline.whisper.model") == "largeV3Turbo")
        #expect(report.preferencesCopied == 1)
        #expect(report.movedModelCache)
    }

    @Test func unreadable_preferences_are_reported_but_do_not_stop_the_move() throws {
        let f = try makeFixture()
        defer { f.tearDown() }
        try populateLegacy(f)
        try "not a plist".write(to: legacyPrefsPlist(f), atomically: true, encoding: .utf8)

        let report = try #require(migration(f).runIfNeeded())

        #expect(report.failures.count == 1)
        #expect(report.preferencesCopied == 0)
        #expect(report.movedModelCache)
        #expect(f.defaults.bool(forKey: ContainerMigration.completedKey))
    }
}
