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

    @Test func record_addsNewestFirst() {
        let store = DictationHistoryStore(defaults: makeDefaults())
        store.record(cleanedText: "first")
        store.record(cleanedText: "second")
        #expect(store.items.count == 2)
        #expect(store.items[0].cleanedText == "second")
        #expect(store.items[1].cleanedText == "first")
    }

    @Test func record_capsAtTen() {
        let store = DictationHistoryStore(defaults: makeDefaults())
        for i in 1...12 {
            store.record(cleanedText: "item \(i)")
        }
        #expect(store.items.count == 10)
        // Newest (item 12) at index 0; oldest retained (item 3) at index 9.
        #expect(store.items[0].cleanedText == "item 12")
        #expect(store.items[9].cleanedText == "item 3")
    }

    @Test func record_skipsWhitespaceOnly() {
        let store = DictationHistoryStore(defaults: makeDefaults())
        store.record(cleanedText: "")
        store.record(cleanedText: "   \n\t  ")
        #expect(store.items.isEmpty)
    }

    @Test func clear_emptiesList() {
        let store = DictationHistoryStore(defaults: makeDefaults())
        store.record(cleanedText: "a")
        store.record(cleanedText: "b")
        store.clear()
        #expect(store.items.isEmpty)
    }

    @Test func persistence_roundTrip() {
        let defaults = makeDefaults()
        let writer = DictationHistoryStore(defaults: defaults)
        writer.record(cleanedText: "alpha")
        writer.record(cleanedText: "beta")
        writer.record(cleanedText: "gamma")

        let reader = DictationHistoryStore(defaults: defaults)
        #expect(reader.items.count == 3)
        #expect(reader.items[0].cleanedText == "gamma")
        #expect(reader.items[1].cleanedText == "beta")
        #expect(reader.items[2].cleanedText == "alpha")
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
        writer.record(cleanedText: "a")
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
