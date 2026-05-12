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
        initial: [String] = [],
        tokenCounter: @escaping @Sendable ([String]) async throws -> Int = { _ in 0 },
        budget: Int = 200
    ) -> (vm: CustomVocabularyListViewModel, store: CustomVocabularyStore) {
        let store = CustomVocabularyStore(defaults: suite())
        store.save(initial)
        let vm = CustomVocabularyListViewModel(
            store: store,
            budget: budget,
            tokenCounter: tokenCounter
        )
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

    @Test func canAdd_is_false_when_typed_term_would_exceed_budget() async {
        let counter: @Sendable ([String]) async throws -> Int = { terms in
            terms.contains("HUGE") ? 999 : 50
        }
        let (vm, _) = makeVM(initial: [], tokenCounter: counter, budget: 200)
        await vm.refreshCount()
        vm.draft = "HUGE"
        await vm.refreshCanAdd()
        #expect(vm.canAdd == false)
    }

    @Test func canAdd_is_true_when_typed_term_fits() async {
        let counter: @Sendable ([String]) async throws -> Int = { _ in 10 }
        let (vm, _) = makeVM(initial: [], tokenCounter: counter, budget: 200)
        await vm.refreshCount()
        vm.draft = "Argmax"
        await vm.refreshCanAdd()
        #expect(vm.canAdd == true)
    }

    @Test func refreshCount_falls_back_to_heuristic_when_counter_throws() async {
        struct E: Error {}
        let counter: @Sendable ([String]) async throws -> Int = { _ in throw E() }
        let (vm, _) = makeVM(initial: ["one two three"], tokenCounter: counter)
        await vm.refreshCount()
        // Heuristic: ~1.3 tokens per word → ceil(3 * 1.3) = 4.
        #expect(vm.tokenCount == 4)
        #expect(vm.tokenCountIsApproximate == true)
    }
}
