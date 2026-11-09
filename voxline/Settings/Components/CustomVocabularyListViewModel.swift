import Foundation
import Observation

/// View-model for `CustomVocabularyListView`. Owns the in-memory terms and
/// persists every mutation through `CustomVocabularyStore`.
@Observable
@MainActor
final class CustomVocabularyListViewModel {

    /// Live, displayed list, in store order.
    private(set) var terms: [String] = []

    /// Bound to the Add field.
    var draft: String = ""

    var footer: String {
        "\(terms.count) term\(terms.count == 1 ? "" : "s")"
    }

    /// True when adding `draft` (trimmed) is meaningful: non-empty and not
    /// already in the list. Drives the Add button's disabled state.
    var canAdd: Bool {
        let trimmed = draft.trimmed
        return !trimmed.isEmpty && !terms.contains(trimmed)
    }

    @ObservationIgnored private let store: CustomVocabularyStore

    init(store: CustomVocabularyStore) {
        self.store = store
        self.terms = store.load()
    }

    func addTerm() {
        let trimmed = draft.trimmed
        guard !trimmed.isEmpty else { return }
        guard !terms.contains(trimmed) else { draft = ""; return }
        store.save(terms + [trimmed])
        draft = ""
        reload()
    }

    func remove(_ term: String) {
        store.save(terms.filter { $0 != term })
        reload()
    }

    func clearAll() {
        store.save([])
        reload()
    }

    private func reload() {
        terms = store.load()
    }
}
