import Foundation
import Observation

/// View-model for `CustomVocabularyListView`. Owns the in-memory `terms`
/// array, persists every mutation through `CustomVocabularyStore`, and keeps
/// an asynchronous token count up to date against an injected
/// `tokenCounter` (typically `TranscriptionService.tokenCount(for:)`).
///
/// The counter is async because counting requires the Whisper tokenizer,
/// which lives behind the model load. The view-model never blocks edits on
/// the counter — it shows a stale count, kicks off a refresh, and updates
/// when it returns.
@Observable
@MainActor
final class CustomVocabularyListViewModel {

    /// Live, displayed list. Stays in user-edit order (store order).
    private(set) var terms: [String] = []

    /// Bound to the Add field.
    var draft: String = ""

    /// Last computed token count of `terms`. May briefly lag mutations
    /// while a refresh is in flight; refreshed on every add/remove.
    private(set) var tokenCount: Int = 0

    /// True when `tokenCount` was produced by the word-heuristic fallback
    /// (counter threw, typically because the Whisper model hasn't loaded
    /// yet). The view shows an "approximate" note when this is true.
    private(set) var tokenCountIsApproximate: Bool = false

    /// True when adding `draft` (trimmed) would not exceed the budget.
    /// Disabled when `draft` is empty-after-trim or a duplicate.
    private(set) var canAdd: Bool = false

    let budget: Int

    private let store: CustomVocabularyStore
    private let tokenCounter: @Sendable ([String]) async throws -> Int

    init(
        store: CustomVocabularyStore,
        budget: Int = WhisperPromptBuilder.promptTokenBudget,
        tokenCounter: @escaping @Sendable ([String]) async throws -> Int
    ) {
        self.store = store
        self.budget = budget
        self.tokenCounter = tokenCounter
        self.terms = store.load()
    }

    func addTerm() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !terms.contains(trimmed) else { draft = ""; return }
        terms.append(trimmed)
        store.save(terms)
        draft = ""
        Task { await self.refreshCount() }
    }

    func remove(_ term: String) {
        terms.removeAll { $0 == term }
        store.save(terms)
        Task { await self.refreshCount() }
    }

    /// Re-read `terms` from the store. Used when something outside the
    /// view-model mutates the store (e.g. `GeneralSettingsViewModel.resetToDefaults`
    /// clears it). Without this the displayed list keeps showing entries the
    /// store no longer holds until the Settings window is reopened.
    func reload() {
        terms = store.load()
        Task { await self.refreshCount() }
    }

    /// Recompute `tokenCount` against the current `terms`. Called on init
    /// (via the view's `.task`), after every mutation, and when the
    /// underlying Whisper model changes.
    func refreshCount() async {
        do {
            tokenCount = try await tokenCounter(terms)
            tokenCountIsApproximate = false
        } catch {
            tokenCount = Self.heuristicCount(of: terms)
            tokenCountIsApproximate = true
        }
        await refreshCanAdd()
    }

    /// Recompute `canAdd` against the current `draft` plus the cached
    /// `tokenCount`. Called from the view as `draft` changes (via
    /// `.onChange`) and after `refreshCount()`.
    func refreshCanAdd() async {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !terms.contains(trimmed) else {
            canAdd = false
            return
        }
        let candidate = terms + [trimmed]
        do {
            let next = try await tokenCounter(candidate)
            canAdd = next <= budget
        } catch {
            // Counter unavailable: fall back to a generous heuristic, but
            // never refuse adds purely because we can't measure.
            canAdd = Self.heuristicCount(of: candidate) <= budget
        }
    }

    /// Word-count heuristic: ~1.3 tokens per whitespace-delimited word.
    /// Used only when the real tokenizer is unreachable.
    private static func heuristicCount(of terms: [String]) -> Int {
        let words = terms.reduce(0) { acc, term in
            acc + term.split(whereSeparator: { $0.isWhitespace }).count
        }
        return Int(ceil(Double(words) * 1.3))
    }
}
