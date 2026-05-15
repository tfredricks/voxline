import Foundation
import Observation

/// View-model for `CustomVocabularyListView`. Owns the in-memory `terms`
/// array and persists every mutation through `CustomVocabularyStore`.
/// Vocab biasing flows through the LLM cleanup prompt.
@Observable
@MainActor
final class CustomVocabularyListViewModel {

    /// Live, displayed list. Stays in user-edit order (store order).
    private(set) var terms: [String] = []

    /// Bound to the Add field.
    var draft: String = ""

    /// True when adding `draft` (trimmed) is meaningful: non-empty and not
    /// already in the list. Drives the Add button's disabled state.
    var canAdd: Bool {
        let trimmed = draft.trimmed
        return !trimmed.isEmpty && !terms.contains(trimmed)
    }

    private let store: CustomVocabularyStore

    init(store: CustomVocabularyStore) {
        self.store = store
        self.terms = store.load()
    }

    func addTerm() {
        let trimmed = draft.trimmed
        guard !trimmed.isEmpty else { return }
        guard !terms.contains(trimmed) else { draft = ""; return }
        terms.append(trimmed)
        store.save(terms)
        draft = ""
    }

    func remove(_ term: String) {
        terms.removeAll { $0 == term }
        store.save(terms)
    }

    /// Re-read `terms` from the store. Used when something outside the
    /// view-model mutates the store (e.g. `GeneralSettingsViewModel.resetToDefaults`
    /// clears it). Without this the displayed list keeps showing entries the
    /// store no longer holds until the Settings window is reopened.
    func reload() {
        terms = store.load()
    }
}
