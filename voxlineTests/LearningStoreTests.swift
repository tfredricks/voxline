import Foundation
import Testing
@testable import voxline

@Suite @MainActor struct LearningStoreTests {

    private func tempFile() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "voxline-learning-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "learning.json")
    }

    /// A clock that moves one second per call, so every record has its own date.
    private func ticking() -> () -> Date {
        var seconds = 0.0
        return {
            seconds += 1
            return Date(timeIntervalSince1970: 1_000 + seconds)
        }
    }

    @Test func round_trips_through_the_file() throws {
        let url = try tempFile()
        let store = LearningStore(fileURL: url, now: ticking())
        store.recordFinalText("Sounds good, see you then", bundleID: "com.apple.MobileSMS", category: .chat)
        store.recordStylePair(before: "Thanks.", after: "Thanks", category: .chat)
        store.setNote("- Drops final periods.", category: .chat, editedByUser: false)
        store.reject(["Kubernetes"])
        let reloaded = LearningStore(fileURL: url)
        #expect(reloaded.data == store.data)
        #expect(reloaded.category(.chat).note == "- Drops final periods.")
    }

    @Test func decoding_tolerates_missing_fields_and_unknown_categories() throws {
        let url = try tempFile()
        try Data(#"{"categories":{"chat":{"note":"Short.","recentTexts":[{"text":"hi"}]},"poetry":{"note":"x"}}}"#.utf8).write(to: url)
        let store = LearningStore(fileURL: url)
        #expect(store.data.version == 1)
        #expect(store.data.rejectedWords == [])
        #expect(store.data.categories.keys.sorted { $0.rawValue < $1.rawValue } == [.chat])
        let chat = store.category(.chat)
        #expect(chat.note == "Short.")
        #expect(chat.noteEditedByUser == false)
        #expect(chat.sinceRefresh == 0)
        #expect(chat.recentTexts.map(\.text) == ["hi"])
        #expect(chat.recentTexts.first?.bundleID == nil)
    }

    @Test func a_corrupt_file_is_moved_aside() throws {
        let url = try tempFile()
        try Data("not json".utf8).write(to: url)
        let store = LearningStore(fileURL: url)
        #expect(store.data == LearningData())
        let aside = url.deletingLastPathComponent().appending(path: "learning.corrupt.json")
        #expect(FileManager.default.fileExists(atPath: aside.path))
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func final_texts_are_capped_and_count_toward_a_refresh() {
        let store = LearningStore(fileURL: nil, now: ticking())
        for i in 1...19 {
            #expect(!store.recordFinalText("text \(i)", bundleID: nil, category: .chat))
        }
        #expect(store.recordFinalText("text 20", bundleID: nil, category: .chat))
        for i in 21...25 { store.recordFinalText("text \(i)", bundleID: nil, category: .chat) }
        let chat = store.category(.chat)
        #expect(chat.recentTexts.count == LearningStore.maxTexts)
        #expect(chat.recentTexts.first?.text == "text 6")
        #expect(chat.recentTexts.last?.text == "text 25")
        #expect(chat.sinceRefresh == 25)
        #expect(!store.recordFinalText("   ", bundleID: nil, category: .chat))
    }

    @Test func long_text_is_cut_to_the_cap() {
        let store = LearningStore(fileURL: nil)
        store.recordFinalText(String(repeating: "a", count: 700), bundleID: nil, category: .email)
        #expect(store.category(.email).recentTexts[0].text.utf16.count == LearningStore.textCap)
        #expect(LearningStore.capped(String(repeating: "a", count: 599) + "👍", 600) == String(repeating: "a", count: 599))
    }

    @Test func style_pairs_are_capped() {
        let store = LearningStore(fileURL: nil, now: ticking())
        store.recordStylePair(before: String(repeating: "a", count: 501), after: "b", category: .chat)
        #expect(store.category(.chat).stylePairs.isEmpty)
        for i in 1...11 { store.recordStylePair(before: "before \(i)", after: "after \(i)", category: .chat) }
        let pairs = store.category(.chat).stylePairs
        #expect(pairs.count == LearningStore.maxPairs)
        #expect(pairs.first?.before == "before 2")
    }

    @Test func notes_are_cut_to_the_cap() {
        let store = LearningStore(fileURL: nil)
        store.setNote(String(repeating: "n", count: 700), category: .chat, editedByUser: true)
        #expect(store.category(.chat).note?.utf16.count == LearningStore.noteCap)
    }

    @Test func a_refreshed_note_restarts_the_count_and_an_edit_does_not() {
        let store = LearningStore(fileURL: nil)
        for i in 1...5 { store.recordFinalText("text \(i)", bundleID: nil, category: .chat) }
        store.setNote("Mine", category: .chat, editedByUser: true)
        #expect(store.category(.chat).sinceRefresh == 5)
        #expect(store.category(.chat).noteEditedByUser)
        store.setNote("Learned", category: .chat, editedByUser: false)
        #expect(store.category(.chat).sinceRefresh == 0)
        #expect(!store.category(.chat).noteEditedByUser)
        #expect(store.category(.chat).noteUpdatedAt != nil)
        store.recordFinalText("again", bundleID: nil, category: .chat)
        store.restartRefreshCount(.chat)
        #expect(store.category(.chat).sinceRefresh == 0)
    }

    @Test func rejected_words_ignore_case_and_keep_the_newest_200() {
        let store = LearningStore(fileURL: nil)
        store.reject(["Kubernetes"])
        #expect(store.isRejected("kubernetes"))
        store.unreject("KUBERNETES")
        #expect(!store.isRejected("Kubernetes"))
        store.reject((1...205).map { "word\($0)" })
        #expect(store.data.rejectedWords.count == LearningStore.maxRejected)
        #expect(store.data.rejectedWords.first == "word6")
    }

    @Test func examples_are_from_the_app_newest_first_and_long_enough() {
        let store = LearningStore(fileURL: nil, now: ticking())
        store.recordFinalText("Sure thing, talk soon!", bundleID: "slack", category: .chat)
        store.recordFinalText("ok", bundleID: "slack", category: .chat)
        store.recordFinalText("Dear team, please find attached.", bundleID: "mail", category: .email)
        store.recordFinalText("Sounds good, shipping it now.", bundleID: "slack", category: .chat)
        store.recordFinalText("Yep, that works for me today.", bundleID: "slack", category: .chat)
        #expect(store.examples(bundleID: "slack") == ["Yep, that works for me today.", "Sounds good, shipping it now."])
        #expect(store.examples(bundleID: "mail", limit: 5) == ["Dear team, please find attached."])
        #expect(store.examples(bundleID: "none").isEmpty)
    }

    @Test func reset_empties_the_data_and_deletes_the_file() throws {
        let url = try tempFile()
        let store = LearningStore(fileURL: url)
        store.recordFinalText("Sounds good", bundleID: nil, category: .chat)
        #expect(FileManager.default.fileExists(atPath: url.path))
        store.reset()
        #expect(store.data == LearningData())
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
