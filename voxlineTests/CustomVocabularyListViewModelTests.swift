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
}
