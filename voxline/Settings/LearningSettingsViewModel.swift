import Foundation
import Observation

/// Settings → Learning. Toggles write through to `AppSettings`; note edits
/// are held as drafts and saved after `noteSaveDelay` of no typing, which
/// marks the note as the user's so automatic refreshes leave it alone.
@Observable
@MainActor
final class LearningSettingsViewModel {

    static let noteSaveDelay: Duration = .seconds(1)
    static let regenerateMinimumTexts = 3

    var learnWords: Bool {
        didSet {
            settings.learnWords = learnWords
            learning.settingsDidChange()
        }
    }

    var learnStyle: Bool {
        didSet {
            settings.learnStyle = learnStyle
            learning.settingsDidChange()
        }
    }

    /// Unsaved note edits, by category.
    private(set) var drafts: [ModeCategory: String] = [:]

    @ObservationIgnored let learning: LearningCoordinator
    @ObservationIgnored private var settings: AppSettings
    @ObservationIgnored private let vocabulary: CustomVocabularyStore
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let locale: Locale
    @ObservationIgnored private var saveTasks: [ModeCategory: Task<Void, Never>] = [:]

    init(learning: LearningCoordinator,
         settings: AppSettings = AppSettings(),
         vocabulary: CustomVocabularyStore = CustomVocabularyStore(),
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         locale: Locale = .current) {
        self.learning = learning
        self.settings = settings
        self.vocabulary = vocabulary
        self.sleep = sleep
        self.locale = locale
        learnWords = settings.learnWords
        learnStyle = settings.learnStyle
    }

    func note(for category: ModeCategory) -> String {
        drafts[category] ?? learning.store.category(category).note ?? ""
    }

    func editNote(_ text: String, for category: ModeCategory) {
        drafts[category] = text
        saveTasks[category]?.cancel()
        saveTasks[category] = Task { [weak self, sleep] in
            do { try await sleep(Self.noteSaveDelay) } catch { return }
            self?.commitDraft(category)
        }
    }

    /// Saves a pending edit now. An edit that leaves the note as it was saves nothing.
    func commitDraft(_ category: ModeCategory) {
        saveTasks[category]?.cancel()
        saveTasks[category] = nil
        guard let draft = drafts.removeValue(forKey: category),
              draft != (learning.store.category(category).note ?? "") else { return }
        learning.store.setNote(draft, category: category, editedByUser: true)
    }

    func commitAllDrafts() {
        for category in Array(drafts.keys) { commitDraft(category) }
    }

    func status(for category: ModeCategory) -> String {
        let entry = learning.store.category(category)
        if learning.refreshing.contains(category) { return "Updating…" }
        if entry.noteEditedByUser { return "Edited by you — automatic updates paused" }
        if entry.note != nil, let updated = entry.noteUpdatedAt {
            let count = min(entry.recentTexts.count, LearningStore.refreshEvery)
            let date = updated.formatted(Date.FormatStyle(locale: locale).month(.abbreviated).day())
            return "Learned from \(count) dictation\(count == 1 ? "" : "s") · updated \(date)"
        }
        return "Appears after \(LearningStore.refreshEvery) dictations (\(entry.sinceRefresh) so far)"
    }

    func canRegenerate(_ category: ModeCategory) -> Bool {
        learning.store.category(category).recentTexts.count >= Self.regenerateMinimumTexts
            && !learning.refreshing.contains(category)
    }

    func needsRegenerateConfirmation(_ category: ModeCategory) -> Bool {
        learning.store.category(category).noteEditedByUser || drafts[category] != nil
    }

    @discardableResult
    func regenerate(_ category: ModeCategory) -> Task<Void, Never>? {
        saveTasks[category]?.cancel()
        saveTasks[category] = nil
        drafts[category] = nil
        return learning.regenerate(category)
    }

    var learnedWordCount: Int {
        vocabulary.entries().filter { $0.source == .learned }.count
    }

    func resetLearning() {
        for task in saveTasks.values { task.cancel() }
        saveTasks = [:]
        drafts = [:]
        learning.reset()
    }
}
