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
}
