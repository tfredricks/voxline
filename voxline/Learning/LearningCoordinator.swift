import Foundation
import Observation

struct InsertedDictation: Equatable, Sendable {
    let text: String
    let bundleID: String?
    let category: ModeCategory
}

struct LearningToggles: Equatable, Sendable {
    var words: Bool
    var style: Bool

    var anyOn: Bool { words || style }

    static func current() -> LearningToggles {
        let settings = AppSettings()
        return LearningToggles(words: settings.learnWords, style: settings.learnStyle)
    }
}

/// What the dictation pipeline tells Learning.
@MainActor
protocol LearningObserving: AnyObject {
    /// A dictation, command, preset, or retry is starting.
    func captureWillStart()
    /// A dictation's text has landed in the focused field.
    func didInsert(_ dictation: InsertedDictation)
    /// The learned style for a dictation in `category` from `bundleID`, or
    /// nil to send none.
    func style(for category: ModeCategory, bundleID: String?) -> LearnedStyle?
}

/// Learning's entry point. Opens a correction window after each dictation
/// insert and turns its end into learned words, style pairs, and final
/// texts. With both toggles off it reads nothing and records nothing.
@Observable
@MainActor
final class LearningCoordinator: LearningObserving {

    static let announcementDuration: Duration = .seconds(5)
    /// An announcement that waited longer than this for idle is dropped.
    static let announcementPatience: TimeInterval = 60

    /// Bumped whenever Learning changes the vocabulary, so Settings reloads it.
    private(set) var vocabularyRevision = 0

    let store: LearningStore

    @ObservationIgnored private let state: AppState
    @ObservationIgnored private let vocabulary: CustomVocabularyStore
    @ObservationIgnored private let reader: any CorrectionReading
    @ObservationIgnored private let dictionary: any WordDictionary
    @ObservationIgnored private let toggles: () -> LearningToggles
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let now: () -> Date
    /// Windows whose end is still wanted: running, or ended by a new capture
    /// and reading their final value. A cancelled window leaves this table,
    /// so anything it reports afterward is dropped.
    @ObservationIgnored private var windows: [UInt64: CorrectionWindow] = [:]
    @ObservationIgnored private var windowID: UInt64 = 0
    @ObservationIgnored private var pending: (words: [String], since: Date)?
    @ObservationIgnored private var observingStatus = false

    init(state: AppState,
         store: LearningStore,
         vocabulary: CustomVocabularyStore,
         reader: any CorrectionReading,
         dictionary: any WordDictionary,
         toggles: @escaping () -> LearningToggles = LearningToggles.current,
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         now: @escaping () -> Date = Date.init) {
        self.state = state
        self.store = store
        self.vocabulary = vocabulary
        self.reader = reader
        self.dictionary = dictionary
        self.toggles = toggles
        self.sleep = sleep
        self.now = now
    }

    func captureWillStart() {
        endOpenWindows()
    }

    func didInsert(_ dictation: InsertedDictation) {
        guard toggles().anyOn else { return }
        endOpenWindows()
        if Self.isUnobservable(dictation.bundleID) {
            logSkip(end: "none", reason: "app")
            recordFinalText(dictation.text, for: dictation)
            return
        }
        windowID &+= 1
        let id = windowID
        let window = CorrectionWindow(reader: reader, sleep: sleep) { [weak self] end in
            self?.windowEnded(end, dictation: dictation, id: id)
        }
        windows[id] = window
        window.start(inserted: dictation.text)
    }

    func style(for category: ModeCategory, bundleID: String?) -> LearnedStyle? {
        guard toggles().style else { return nil }
        let note = store.category(category).note
        let examples = bundleID.map { store.examples(bundleID: $0) } ?? []
        guard note != nil || !examples.isEmpty else { return nil }
        return LearnedStyle(categoryName: category.displayName, note: note, examples: examples)
    }

    /// Called when a Learning toggle changes. With both off, an open window
    /// is cancelled with no final read.
    func settingsDidChange() {
        guard !toggles().anyOn else { return }
        cancelWindows()
    }

    /// Forgets notes, texts, pairs, and rejected words, and removes learned
    /// words from the vocabulary. Words the user added stay.
    func reset() {
        cancelWindows()
        pending = nil
        let removed = vocabulary.removeLearned()
        store.reset()
        if !removed.isEmpty { vocabularyRevision += 1 }
    }

    /// The toast's Undo: removes `words` and stops them being learned again.
    func undo(_ words: [String]) {
        for word in words { vocabulary.remove(word) }
        store.reject(words)
        vocabularyRevision += 1
        state.flashToast("Removed: \(words.joined(separator: ", "))")
    }

    /// Terminals show scrollback, and these editors expose a hidden input
    /// rather than the document, so their values say nothing about edits.
    static func isUnobservable(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return InsertionPlan.isTerminal(bundleID) || EditContextPolicy.default.untrustedFieldBundleIDs.contains(bundleID)
    }

    private func endOpenWindows() {
        for window in windows.values { window.endForNewCapture() }
    }

    private func cancelWindows() {
        for window in windows.values { window.cancel() }
        windows.removeAll()
    }

    private func windowEnded(_ end: WindowEnd, dictation: InsertedDictation, id: UInt64) {
        guard windows.removeValue(forKey: id) != nil else { return }
        let toggles = self.toggles()
        guard toggles.anyOn else { return }
        switch end {
        case .skipped(let reason):
            logSkip(end: reason == .superseded ? WindowEndReason.newCapture.rawValue : "anchor", reason: reason.rawValue)
            recordFinalText(dictation.text, for: dictation)
        case .finished(let result):
            apply(result, dictation: dictation, toggles: toggles)
        }
    }

    private func apply(_ result: WindowResult, dictation: InsertedDictation, toggles: LearningToggles) {
        var classification = Classification()
        var learned: [String] = []
        switch result.match {
        case .changed(let region):
            classification = CorrectionClassifier.classify(
                inserted: result.anchor.inserted, corrected: region, before: result.anchor.prefix, dictionary: dictionary
            )
            if toggles.words { learned = learn(classification.vocabulary) }
            if toggles.style, classification.isStyleSignal {
                store.recordStylePair(before: result.anchor.inserted, after: region, category: dictation.category)
            }
            recordFinalText(region, for: dictation)
        case .unchanged, .ambiguous, .unreadable:
            recordFinalText(dictation.text, for: dictation)
        case .discarded:
            break
        }
        AppLog.learning.info("window end=\(result.reason.rawValue, privacy: .public) region=\(result.match.logName, privacy: .public) hunks=\(classification.hunkCount) vocab=\(learned.count) style=\(classification.isStyleSignal ? 1 : 0) source=\(result.source.rawValue, privacy: .public) ticks=\(result.ticks)")
    }

    /// The window line for a window that never anchored: `end=anchor` when
    /// the anchor read refused, `end=none` when no window was opened.
    private func logSkip(end: String, reason: String) {
        AppLog.learning.info("window end=\(end, privacy: .public) region=skipped:\(reason, privacy: .public) hunks=0 vocab=0 style=0")
    }

    private func learn(_ candidates: [String]) -> [String] {
        var added: [String] = []
        for word in candidates where !store.isRejected(word) {
            if vocabulary.addLearned(word) { added.append(word) }
        }
        guard !added.isEmpty else { return [] }
        vocabularyRevision += 1
        announce(added)
        return added
    }

    private func recordFinalText(_ text: String, for dictation: InsertedDictation) {
        guard toggles().style else { return }
        store.recordFinalText(text, bundleID: dictation.bundleID, category: dictation.category)
    }

    private func announce(_ words: [String]) {
        pending = ((pending?.words ?? []) + words, now())
        flushAnnouncement()
    }

    private func flushAnnouncement() {
        guard let pending else { return }
        guard state.status == .idle else {
            observeStatusForAnnouncement()
            return
        }
        self.pending = nil
        guard now().timeIntervalSince(pending.since) <= Self.announcementPatience else { return }
        let words = pending.words
        state.flashToast(
            "Learned: \(words.joined(separator: ", "))",
            for: Self.announcementDuration,
            action: ToastAction(title: "Undo") { [weak self] in self?.undo(words) }
        )
    }

    private func observeStatusForAnnouncement() {
        guard !observingStatus else { return }
        observingStatus = true
        withObservationTracking {
            _ = state.status
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.observingStatus = false
                self.flushAnnouncement()
            }
        }
    }
}

extension LearningCoordinator {
    /// The app's instance: `learning.json`, the standard vocabulary, live
    /// AX reads, and the system spelling dictionary.
    static func live(state: AppState) -> LearningCoordinator {
        LearningCoordinator(
            state: state,
            store: LearningStore.standard(),
            vocabulary: CustomVocabularyStore(),
            reader: LiveCorrectionReader(),
            dictionary: SpellCheckDictionary()
        )
    }
}
