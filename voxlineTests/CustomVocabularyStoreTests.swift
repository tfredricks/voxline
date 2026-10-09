import Testing
import Foundation
@testable import voxline

@Suite struct CustomVocabularyStoreTests {

    private func suite() -> UserDefaults {
        let name = "voxline-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func load_returns_empty_when_unset() {
        let store = CustomVocabularyStore(defaults: suite())
        #expect(store.load() == [])
    }

    @Test func save_then_load_roundtrips_terms() {
        let store = CustomVocabularyStore(defaults: suite())
        store.save(["Cursor", "LangGraph", "canonical_title"])
        #expect(store.load() == ["Cursor", "LangGraph", "canonical_title"])
    }

    @Test func save_trims_whitespace_and_drops_empty_entries() {
        let store = CustomVocabularyStore(defaults: suite())
        store.save(["  Cursor  ", "", "   ", "LangGraph\n"])
        #expect(store.load() == ["Cursor", "LangGraph"])
    }

    @Test func save_dedupes_case_sensitive() {
        let store = CustomVocabularyStore(defaults: suite())
        store.save(["Cursor", "Cursor", "cursor"])
        #expect(store.load() == ["Cursor", "cursor"])
    }

    @Test func parse_from_text_handles_comma_and_newline_separated() {
        let parsed = CustomVocabularyStore.parse("Cursor, LangGraph\ncanonical_title,,  ")
        #expect(parsed == ["Cursor", "LangGraph", "canonical_title"])
    }

    @Test func entries_without_a_sidecar_are_all_user() {
        let store = CustomVocabularyStore(defaults: suite())
        store.save(["Cursor", "LangGraph"])
        #expect(store.entries() == [
            VocabularyEntry(term: "Cursor", source: .user),
            VocabularyEntry(term: "LangGraph", source: .user),
        ])
    }

    @Test func addLearned_appends_and_marks_the_term() {
        let store = CustomVocabularyStore(defaults: suite())
        store.save(["Cursor"])
        #expect(store.addLearned("Argmax"))
        #expect(store.load() == ["Cursor", "Argmax"])
        #expect(store.entries().last == VocabularyEntry(term: "Argmax", source: .learned))
    }

    @Test func addLearned_skips_a_term_already_present_in_any_case_and_blanks() {
        let store = CustomVocabularyStore(defaults: suite())
        store.save(["argmax"])
        #expect(!store.addLearned("Argmax"))
        #expect(!store.addLearned("   "))
        #expect(store.load() == ["argmax"])
    }

    @Test func remove_returns_the_entry_and_forgets_the_learned_mark() {
        let store = CustomVocabularyStore(defaults: suite())
        store.addLearned("Argmax")
        #expect(store.remove("Argmax") == VocabularyEntry(term: "Argmax", source: .learned))
        #expect(store.remove("Argmax") == nil)
        store.save(["Argmax"])
        #expect(store.entries() == [VocabularyEntry(term: "Argmax", source: .user)])
    }

    @Test func removeAll_returns_every_entry() {
        let store = CustomVocabularyStore(defaults: suite())
        store.save(["Cursor"])
        store.addLearned("Argmax")
        #expect(store.removeAll() == [
            VocabularyEntry(term: "Cursor", source: .user),
            VocabularyEntry(term: "Argmax", source: .learned),
        ])
        #expect(store.load() == [])
    }

    @Test func removeLearned_keeps_user_terms() {
        let store = CustomVocabularyStore(defaults: suite())
        store.save(["Cursor"])
        store.addLearned("Argmax")
        store.addLearned("Kubernetes")
        #expect(store.removeLearned() == ["Argmax", "Kubernetes"])
        #expect(store.entries() == [VocabularyEntry(term: "Cursor", source: .user)])
    }
}
