import Foundation
import Observation

/// View-model for `CustomVocabularyListView`. Owns the in-memory entries and
/// persists every mutation through `CustomVocabularyStore`. Removing a
/// learned term reports it, so Learning never learns it again; adding a
/// term by hand reports it too.
@Observable
@MainActor
final class CustomVocabularyListViewModel {

    /// Live, displayed list, in store order.
    private(set) var entries: [VocabularyEntry] = []

    /// Bound to the Add field.
    var draft: String = ""

    var terms: [String] { entries.map(\.term) }

    var learnedCount: Int { entries.filter { $0.source == .learned }.count }

    /// "N terms", plus "(M learned)" when any are.
    var footer: String {
        let count = "\(entries.count) term\(entries.count == 1 ? "" : "s")"
        return learnedCount > 0 ? "\(count) (\(learnedCount) learned)" : count
    }

    /// True when adding `draft` (trimmed) is meaningful: non-empty and not
    /// already in the list. Drives the Add button's disabled state.
    var canAdd: Bool {
        let trimmed = draft.trimmed
        return !trimmed.isEmpty && !terms.contains(trimmed)
    }

    @ObservationIgnored private let store: CustomVocabularyStore
    @ObservationIgnored private let onRemoveLearned: ([String]) -> Void
    @ObservationIgnored private let onAdd: (String) -> Void

    init(store: CustomVocabularyStore,
         onRemoveLearned: @escaping ([String]) -> Void = { _ in },
         onAdd: @escaping (String) -> Void = { _ in }) {
        self.store = store
        self.onRemoveLearned = onRemoveLearned
        self.onAdd = onAdd
        self.entries = store.entries()
    }

    func addTerm() {
        let trimmed = draft.trimmed
        guard !trimmed.isEmpty else { return }
        guard !terms.contains(trimmed) else { draft = ""; return }
        store.save(terms + [trimmed])
        onAdd(trimmed)
        draft = ""
        reload()
    }

    func remove(_ term: String) {
        if let removed = store.remove(term), removed.source == .learned {
            onRemoveLearned([term])
        }
        reload()
    }

    func clearAll() {
        let learned = store.removeAll().filter { $0.source == .learned }.map(\.term)
        if !learned.isEmpty { onRemoveLearned(learned) }
        reload()
    }

    /// Re-read the entries from the store. Used when something outside the
    /// view-model changes it (Learning adding or removing a word).
    func reload() {
        entries = store.entries()
    }
}
