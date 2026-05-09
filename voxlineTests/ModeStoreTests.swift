import Testing
import Foundation
@testable import voxline

@Suite struct ModeStoreTests {

    /// Build a ModeStore against a fresh per-test directory so we don't
    /// touch the real Application Support modes.json.
    private func makeStore() -> (store: ModeStore, dir: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxline-modestore-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("modes.json")
        return (ModeStore(fileURL: url), dir)
    }

    @Test func load_on_missing_file_returns_shipped_defaults_and_creates_file() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let modes = try store.load()
        #expect(modes == ModeStore.shippedDefaults)
        #expect(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    @Test func save_then_load_round_trip() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let custom = [
            Mode(bundleID: "com.apple.notes", displayName: "Notes", prompt: "casual", model: nil, temperature: nil)
        ]
        try store.save(custom)
        let loaded = try store.load()
        #expect(loaded == custom)
    }

    @Test func shipped_defaults_include_wildcard_fallback() {
        #expect(ModeStore.shippedDefaults.contains(where: { $0.bundleID == Mode.wildcardBundleID }))
    }

    @Test func shipped_defaults_cover_slack_mail_cursor() {
        let ids = Set(ModeStore.shippedDefaults.map(\.bundleID))
        #expect(ids.contains("com.tinyspeck.slackmacgap"))
        #expect(ids.contains("com.apple.mail"))
        #expect(ids.contains("com.todesktop.230313mzl4w4u92"))
    }
}
