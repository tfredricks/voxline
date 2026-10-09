import Testing
import Foundation
@testable import voxline

@Suite @MainActor struct CustomVocabularyListViewModelTests {

    private func suite() -> UserDefaults {
        let name = "voxline-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    private func makeVM(
        initial: [String] = []
    ) -> (vm: CustomVocabularyListViewModel, store: CustomVocabularyStore) {
        let store = CustomVocabularyStore(defaults: suite())
        store.save(initial)
        let vm = CustomVocabularyListViewModel(store: store)
        return (vm, store)
    }

    @Test func loadFromStore_populates_terms_in_order() {
        let (vm, _) = makeVM(initial: ["Argmax", "LangGraph", "MSL"])
        #expect(vm.terms == ["Argmax", "LangGraph", "MSL"])
    }

    @Test func addTerm_trims_and_persists() {
        let (vm, store) = makeVM()
        vm.draft = "  Argmax  "
        vm.addTerm()
        #expect(vm.terms == ["Argmax"])
        #expect(store.load() == ["Argmax"])
        #expect(vm.draft == "")
    }

    @Test func addTerm_ignores_exact_duplicate() {
        let (vm, _) = makeVM(initial: ["Argmax"])
        vm.draft = "Argmax"
        vm.addTerm()
        #expect(vm.terms == ["Argmax"])
    }

    @Test func addTerm_ignores_empty_after_trim() {
        let (vm, _) = makeVM()
        vm.draft = "   "
        vm.addTerm()
        #expect(vm.terms.isEmpty)
    }

    @Test func removeTerm_persists() {
        let (vm, store) = makeVM(initial: ["Argmax", "LangGraph"])
        vm.remove("Argmax")
        #expect(vm.terms == ["LangGraph"])
        #expect(store.load() == ["LangGraph"])
    }

    @Test func canAdd_is_false_when_draft_is_empty_after_trim() {
        let (vm, _) = makeVM()
        vm.draft = "   "
        #expect(vm.canAdd == false)
    }

    @Test func canAdd_is_false_when_draft_duplicates_existing_term() {
        let (vm, _) = makeVM(initial: ["Argmax"])
        vm.draft = "Argmax"
        #expect(vm.canAdd == false)
    }

    @Test func canAdd_is_true_for_new_nonempty_term() {
        let (vm, _) = makeVM(initial: ["Argmax"])
        vm.draft = "LangGraph"
        #expect(vm.canAdd == true)
    }

    private func makeLearningVM(
        removed: LockedBox<[[String]]> = LockedBox([]),
        added: LockedBox<[String]> = LockedBox([])
    ) -> (vm: CustomVocabularyListViewModel, store: CustomVocabularyStore) {
        let store = CustomVocabularyStore(defaults: suite())
        store.save(["Cursor"])
        store.addLearned("Argmax")
        let vm = CustomVocabularyListViewModel(
            store: store,
            onRemoveLearned: { words in removed.mutate { $0.append(words) } },
            onAdd: { word in added.mutate { $0.append(word) } }
        )
        return (vm, store)
    }

    @Test func learned_entries_are_labelled_and_counted() {
        let (vm, _) = makeLearningVM()
        #expect(vm.entries == [
            VocabularyEntry(term: "Cursor", source: .user),
            VocabularyEntry(term: "Argmax", source: .learned),
        ])
        #expect(vm.learnedCount == 1)
        #expect(vm.footer == "2 terms (1 learned)")
    }

    @Test func footer_without_learned_terms() {
        let (vm, _) = makeVM(initial: ["Argmax"])
        #expect(vm.footer == "1 term")
    }

    @Test func removing_a_learned_term_rejects_it_and_a_user_term_does_not() {
        let removed = LockedBox<[[String]]>([])
        let (vm, _) = makeLearningVM(removed: removed)
        vm.remove("Cursor")
        #expect(removed.read().isEmpty)
        vm.remove("Argmax")
        #expect(removed.read() == [["Argmax"]])
        #expect(vm.entries.isEmpty)
    }

    @Test func adding_a_term_reports_it() {
        let added = LockedBox<[String]>([])
        let (vm, _) = makeLearningVM(added: added)
        vm.draft = "Kubernetes"
        vm.addTerm()
        #expect(added.read() == ["Kubernetes"])
        #expect(vm.entries.last == VocabularyEntry(term: "Kubernetes", source: .user))
    }

    @Test func clearAll_removes_everything_and_rejects_learned_terms() {
        let removed = LockedBox<[[String]]>([])
        let (vm, store) = makeLearningVM(removed: removed)
        vm.clearAll()
        #expect(vm.entries.isEmpty)
        #expect(store.load().isEmpty)
        #expect(removed.read() == [["Argmax"]])
    }
}
