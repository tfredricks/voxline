import Testing
import Foundation
@testable import voxline

@Suite @MainActor struct DictationHistoryStoreTests {

    /// Per-test isolated suite so we don't trample the user's real defaults.
    private func makeDefaults() -> UserDefaults {
        let suiteName = "voxline-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    /// Throwaway Mode for tests that don't care about mode capture.
    private func anyMode() -> Mode {
        Mode(bundleID: "*", displayName: "Default", prompt: "p", model: nil, temperature: nil)
    }

    @Test func record_addsNewestFirst() {
        let store = DictationHistoryStore(defaults: makeDefaults())
        store.record(cleanedText: "first", mode: anyMode(), context: .empty)
        store.record(cleanedText: "second", mode: anyMode(), context: .empty)
        #expect(store.items.count == 2)
        #expect(store.items[0].cleanedText == "second")
        #expect(store.items[1].cleanedText == "first")
    }

    @Test func record_caps_at_25_dropping_oldest() {
        let suite = UserDefaults(suiteName: "voxline.history.test.\(UUID().uuidString)")!
        defer { suite.removePersistentDomain(forName: "voxline.history.test") }
        let store = DictationHistoryStore(defaults: suite)
        let mode = Mode(bundleID: "*", displayName: "Default", prompt: "p", model: nil, temperature: nil)

        for i in 0..<30 {
            store.record(cleanedText: "entry \(i)", mode: mode, context: .empty)
        }

        #expect(store.items.count == 25)
        // Newest first: "entry 29" wins; "entry 0..4" should have been evicted.
        #expect(store.items.first?.cleanedText == "entry 29")
        #expect(store.items.contains(where: { $0.cleanedText == "entry 4" }) == false)
        #expect(store.items.contains(where: { $0.cleanedText == "entry 5" }) == true)
    }

    @Test func record_skipsWhitespaceOnly() {
        let store = DictationHistoryStore(defaults: makeDefaults())
        store.record(cleanedText: "", mode: anyMode(), context: .empty)
        store.record(cleanedText: "   \n\t  ", mode: anyMode(), context: .empty)
        #expect(store.items.isEmpty)
    }

    @Test func clear_emptiesList() {
        let store = DictationHistoryStore(defaults: makeDefaults())
        store.record(cleanedText: "a", mode: anyMode(), context: .empty)
        store.record(cleanedText: "b", mode: anyMode(), context: .empty)
        store.clear()
        #expect(store.items.isEmpty)
    }

    @Test func persistence_roundTrip() {
        let defaults = makeDefaults()
        let writer = DictationHistoryStore(defaults: defaults)
        writer.record(cleanedText: "alpha", mode: anyMode(), context: .empty)
        writer.record(cleanedText: "beta", mode: anyMode(), context: .empty)
        writer.record(cleanedText: "gamma", mode: anyMode(), context: .empty)

        let reader = DictationHistoryStore(defaults: defaults)
        #expect(reader.items.count == 3)
        #expect(reader.items[0].cleanedText == "gamma")
        #expect(reader.items[1].cleanedText == "beta")
        #expect(reader.items[2].cleanedText == "alpha")
    }

    @Test func record_captures_mode_fields() {
        let suite = UserDefaults(suiteName: "voxline.history.test.\(UUID().uuidString)")!
        defer { suite.removePersistentDomain(forName: "voxline.history.test") }
        let store = DictationHistoryStore(defaults: suite)

        let mode = Mode(
            bundleID: "com.test.app",
            displayName: "Test",
            prompt: "p",
            model: nil,
            temperature: nil
        )
        store.record(cleanedText: "hi", mode: mode, context: .empty)

        let item = try! #require(store.items.first)
        #expect(item.modeDisplayName == "Test")
        #expect(item.modeBundleID == "com.test.app")
    }

    @Test func record_captures_app_fields_from_context() {
        let suite = UserDefaults(suiteName: "voxline.history.test.\(UUID().uuidString)")!
        defer { suite.removePersistentDomain(forName: "voxline.history.test") }
        let store = DictationHistoryStore(defaults: suite)

        var ctx = CapturedContext.empty
        ctx.appName = "Slack"
        ctx.bundleID = "com.tinyspeck.slackmacgap"
        let mode = Mode(bundleID: "*", displayName: "Default", prompt: "p", model: nil, temperature: nil)
        store.record(cleanedText: "hello team", mode: mode, context: ctx)

        let item = try! #require(store.items.first)
        #expect(item.appName == "Slack")
        #expect(item.appBundleID == "com.tinyspeck.slackmacgap")
    }

    @Test func record_empty_context_stores_nil_app_fields() {
        let suite = UserDefaults(suiteName: "voxline.history.test.\(UUID().uuidString)")!
        defer { suite.removePersistentDomain(forName: "voxline.history.test") }
        let store = DictationHistoryStore(defaults: suite)

        let mode = Mode(bundleID: "*", displayName: "Default", prompt: "p", model: nil, temperature: nil)
        store.record(cleanedText: "x", mode: mode, context: .empty)

        let item = try! #require(store.items.first)
        #expect(item.appName == nil)
        #expect(item.appBundleID == nil)
    }

    @Test func persistence_handlesCorruptData() {
        let defaults = makeDefaults()
        defaults.set(Data([0x00, 0x01, 0x02]), forKey: DictationHistoryStore.key)
        let store = DictationHistoryStore(defaults: defaults)
        #expect(store.items.isEmpty)
    }

    @Test func clear_persistsEmpty() {
        let defaults = makeDefaults()
        let writer = DictationHistoryStore(defaults: defaults)
        writer.record(cleanedText: "a", mode: anyMode(), context: .empty)
        writer.clear()
        let reader = DictationHistoryStore(defaults: defaults)
        #expect(reader.items.isEmpty)
    }

    @Test func loads_old_schema_json_with_nil_new_fields() throws {
        // The 1.0 history shape: only id/timestamp/cleanedText. Existing users
        // upgrading must keep their history; the new fields decode as nil.
        let suite = UserDefaults(suiteName: "voxline.history.test.\(UUID().uuidString)")!
        defer { suite.removePersistentDomain(forName: "voxline.history.test") }

        let oldJSON = #"""
        [
          {"id":"00000000-0000-0000-0000-000000000001","timestamp":770000000.0,"cleanedText":"hello"},
          {"id":"00000000-0000-0000-0000-000000000002","timestamp":770000001.0,"cleanedText":"world"}
        ]
        """#.data(using: .utf8)!
        suite.set(oldJSON, forKey: DictationHistoryStore.key)

        let store = DictationHistoryStore(defaults: suite)

        #expect(store.items.count == 2)
        let first = try #require(store.items.first)
        #expect(first.cleanedText == "hello")
        #expect(first.modeDisplayName == nil)
        #expect(first.modeBundleID == nil)
        #expect(first.appName == nil)
        #expect(first.appBundleID == nil)
    }
}
