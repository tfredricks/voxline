import ApplicationServices
import Foundation
import Testing
@testable import voxline

@Suite(.timeLimit(.minutes(1))) @MainActor struct LearningCoordinatorTests {

    static let original = "ask Cooper Nettis to review"
    static let fixed = "ask Kubernetes to review"
    static let messages = "com.apple.MobileSMS"

    struct Harness {
        let learning: LearningCoordinator
        let state: AppState
        let store: LearningStore
        let vocabulary: CustomVocabularyStore
        let reader: FakeCorrectionReader
        let clock: ManualClock
        let toggles: LockedBox<LearningToggles>
        let now: LockedBox<Date>
    }

    private func makeHarness(
        original: String = Self.original,
        values: [AXRead<String>] = [.value(Self.fixed)],
        anchors: [AnchorRead]? = nil,
        toggles: LearningToggles = LearningToggles(words: true, style: true),
        anchorBlock: DispatchSemaphore? = nil,
        generator: FakeStyleGenerator? = nil
    ) -> Harness {
        let element = FakeAXTextElement()
        let reader = FakeCorrectionReader(
            anchors: anchors ?? [FakeCorrectionReader.anchored(element, value: original, inserted: original)],
            focus: [.value(element.ref)],
            values: values,
            anchorBlock: anchorBlock
        )
        let suiteName = "voxline-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let clock = ManualClock()
        let togglesBox = LockedBox(toggles)
        let nowBox = LockedBox(Date(timeIntervalSince1970: 1_000))
        let state = AppState()
        let store = LearningStore(fileURL: nil, now: { nowBox.read() })
        let vocabulary = CustomVocabularyStore(defaults: defaults)
        let learning = LearningCoordinator(
            state: state, store: store, vocabulary: vocabulary, reader: reader,
            dictionary: FakeWordDictionary(),
            toggles: { togglesBox.read() },
            sleep: { @MainActor in try await clock.sleep($0) },
            now: { nowBox.read() },
            generator: generator, model: { "test-model" }
        )
        return Harness(learning: learning, state: state, store: store, vocabulary: vocabulary,
                       reader: reader, clock: clock, toggles: togglesBox, now: nowBox)
    }

    /// Inserts `text`, waits for the anchor read and the first poll's sleep,
    /// then ends the window the way the next dictation would.
    private func dictateAndEnd(_ h: Harness, text: String = Self.original, bundleID: String? = Self.messages) async {
        let anchorsBefore = h.reader.anchorCalls
        h.learning.didInsert(InsertedDictation(text: text, bundleID: bundleID, category: .chat))
        #expect(await eventually { h.reader.anchorCalls == anchorsBefore + 1 && h.clock.pendingCount == 1 })
        h.learning.captureWillStart()
    }

    private func texts(_ h: Harness) -> [String] {
        h.store.category(.chat).recentTexts.map(\.text)
    }

    @Test func learns_a_fixed_name_and_announces_it_with_undo() async {
        let h = makeHarness()
        await dictateAndEnd(h)
        #expect(await eventually { h.state.toastMessage == "Learned: Kubernetes" })
        #expect(h.state.toastAction?.title == "Undo")
        #expect(h.vocabulary.entries() == [VocabularyEntry(term: "Kubernetes", source: .learned)])
        #expect(h.learning.vocabularyRevision == 1)
        #expect(texts(h) == [Self.fixed])
        #expect(h.store.category(.chat).stylePairs.isEmpty)
    }

    @Test func undo_removes_and_rejects_the_word() async {
        let h = makeHarness()
        await dictateAndEnd(h)
        #expect(await eventually { h.state.toastAction != nil })
        h.state.toastAction?.perform()
        #expect(h.vocabulary.load().isEmpty)
        #expect(h.store.isRejected("kubernetes"))
        #expect(h.state.toastMessage == "Removed: Kubernetes")
        #expect(h.learning.vocabularyRevision == 2)
    }

    @Test func rejected_and_already_listed_words_are_not_learned() async {
        let rejected = makeHarness()
        rejected.store.reject(["Kubernetes"])
        await dictateAndEnd(rejected)
        #expect(await eventually { rejected.store.category(.chat).recentTexts.count == 1 })
        #expect(rejected.vocabulary.load().isEmpty)
        #expect(rejected.state.toastMessage == nil)

        let listed = makeHarness()
        listed.vocabulary.save(["kubernetes"])
        await dictateAndEnd(listed)
        #expect(await eventually { listed.store.category(.chat).recentTexts.count == 1 })
        #expect(listed.vocabulary.entries() == [VocabularyEntry(term: "kubernetes", source: .user)])
        #expect(listed.state.toastMessage == nil)
    }

    @Test func a_style_edit_records_a_pair_and_no_word() async {
        let h = makeHarness(original: "Thanks for the help.", values: [.value("Thanks for the help")])
        await dictateAndEnd(h, text: "Thanks for the help.")
        #expect(await eventually { h.store.category(.chat).stylePairs.count == 1 })
        let pair = h.store.category(.chat).stylePairs[0]
        #expect(pair.before == "Thanks for the help." && pair.after == "Thanks for the help")
        #expect(texts(h) == ["Thanks for the help"])
        #expect(h.vocabulary.load().isEmpty)
    }

    @Test func word_learning_off_still_records_style() async {
        let h = makeHarness(toggles: LearningToggles(words: false, style: true))
        await dictateAndEnd(h)
        #expect(await eventually { texts(h) == [Self.fixed] })
        #expect(h.vocabulary.load().isEmpty)
    }

    @Test func style_learning_off_still_learns_words_and_keeps_no_text() async {
        let h = makeHarness(toggles: LearningToggles(words: true, style: false))
        await dictateAndEnd(h)
        #expect(await eventually { h.vocabulary.load() == ["Kubernetes"] })
        #expect(h.store.data == LearningData())
    }

    @Test func both_off_reads_nothing_and_keeps_nothing() async {
        let h = makeHarness(toggles: LearningToggles(words: false, style: false))
        h.learning.didInsert(InsertedDictation(text: Self.original, bundleID: Self.messages, category: .chat))
        h.learning.captureWillStart()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(h.reader.anchorCalls == 0)
        #expect(h.store.data == LearningData())
        #expect(h.vocabulary.load().isEmpty)
    }

    @Test func turning_both_off_mid_window_cancels_the_final_read() async {
        let h = makeHarness()
        h.learning.didInsert(InsertedDictation(text: Self.original, bundleID: Self.messages, category: .chat))
        #expect(await eventually { h.clock.pendingCount == 1 })
        h.toggles.write(LearningToggles(words: false, style: false))
        h.learning.settingsDidChange()
        h.learning.captureWillStart()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(h.reader.valueCalls == 0)
        #expect(h.vocabulary.load().isEmpty)
    }

    @Test func terminals_and_untrusted_fields_get_no_window() async {
        let h = makeHarness()
        h.learning.didInsert(InsertedDictation(text: Self.original, bundleID: "com.apple.Terminal", category: .chat))
        h.learning.didInsert(InsertedDictation(text: Self.original, bundleID: "com.microsoft.VSCode", category: .chat))
        #expect(h.reader.anchorCalls == 0)
        #expect(texts(h) == [Self.original, Self.original])
        #expect(LearningCoordinator.isUnobservable("com.googlecode.iterm2"))
        #expect(!LearningCoordinator.isUnobservable(Self.messages))
        #expect(!LearningCoordinator.isUnobservable(nil))
    }

    @Test func a_skipped_anchor_records_the_inserted_text() async {
        let h = makeHarness(anchors: [.skipped(.valueUnreadable)])
        h.learning.didInsert(InsertedDictation(text: Self.original, bundleID: Self.messages, category: .chat))
        #expect(await eventually { texts(h) == [Self.original] })
    }

    @Test func a_discarded_dictation_records_nothing() async {
        let h = makeHarness(values: [.value("")])
        await dictateAndEnd(h)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(h.reader.valueCalls == 1)
        #expect(h.store.data == LearningData())
    }

    @Test func fix_then_send_learns_from_the_last_good_snapshot() async {
        let h = makeHarness(values: [.value(Self.fixed), .value("")])
        h.learning.didInsert(InsertedDictation(text: Self.original, bundleID: Self.messages, category: .chat))
        #expect(await eventually { h.clock.pendingCount == 1 })
        await h.clock.advance(by: CorrectionWindow.tick)
        #expect(await eventually { h.reader.valueCalls == 1 && h.clock.pendingCount == 1 })
        h.learning.captureWillStart()
        #expect(await eventually { h.vocabulary.load() == ["Kubernetes"] })
    }

    @Test func the_announcement_waits_for_idle() async {
        let h = makeHarness()
        h.state.status = .thinking
        await dictateAndEnd(h)
        #expect(await eventually { h.vocabulary.load() == ["Kubernetes"] })
        #expect(h.state.toastMessage == nil)
        h.state.status = .idle
        #expect(await eventually { h.state.toastMessage == "Learned: Kubernetes" })
    }

    @Test func a_stale_announcement_is_dropped_but_the_word_stays() async {
        let h = makeHarness()
        h.state.status = .thinking
        await dictateAndEnd(h)
        #expect(await eventually { h.vocabulary.load() == ["Kubernetes"] })
        h.now.write(h.now.read().addingTimeInterval(61))
        h.state.status = .idle
        try? await Task.sleep(for: .milliseconds(50))
        #expect(h.state.toastMessage == nil)
        #expect(h.vocabulary.load() == ["Kubernetes"])
    }

    @Test func reset_forgets_learning_and_learned_words_only() async {
        let h = makeHarness()
        h.vocabulary.save(["Cursor"])
        await dictateAndEnd(h)
        #expect(await eventually { h.vocabulary.load() == ["Cursor", "Kubernetes"] })
        h.learning.reset()
        #expect(h.vocabulary.load() == ["Cursor"])
        #expect(h.store.data == LearningData())
    }

    @Test func a_result_from_a_replaced_window_is_ignored() async {
        let gate = DispatchSemaphore(value: 0)
        let h = makeHarness(anchorBlock: gate)
        h.learning.didInsert(InsertedDictation(text: Self.original, bundleID: Self.messages, category: .chat))
        #expect(await eventually { h.reader.anchorCalls == 1 })
        h.learning.reset()
        gate.signal()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(h.reader.valueCalls == 0)
        #expect(h.store.data == LearningData())
        #expect(h.vocabulary.load().isEmpty)
    }

    @Test func a_new_dictation_still_lets_the_previous_window_finish() async {
        let h = makeHarness(values: [.value(Self.fixed)])
        h.learning.didInsert(InsertedDictation(text: Self.original, bundleID: Self.messages, category: .chat))
        #expect(await eventually { h.clock.pendingCount == 1 })
        h.learning.captureWillStart()
        h.learning.didInsert(InsertedDictation(text: "unrelated", bundleID: Self.messages, category: .chat))
        #expect(await eventually { h.vocabulary.load() == ["Kubernetes"] })
    }

    @Test func style_carries_the_note_and_examples_from_the_same_app() {
        let h = makeHarness()
        #expect(h.learning.style(for: .chat, bundleID: Self.messages) == nil)
        h.store.setNote("- Drops final periods.", category: .chat, editedByUser: false)
        h.store.recordFinalText("Sounds good, see you at noon", bundleID: Self.messages, category: .chat)
        h.store.recordFinalText("Another app entirely, long text", bundleID: "other", category: .chat)
        #expect(h.learning.style(for: .chat, bundleID: Self.messages)
                == LearnedStyle(categoryName: "Chat", note: "- Drops final periods.", examples: ["Sounds good, see you at noon"]))
        #expect(h.learning.style(for: .chat, bundleID: nil)
                == LearnedStyle(categoryName: "Chat", note: "- Drops final periods.", examples: []))
        #expect(h.learning.style(for: .email, bundleID: "none") == nil)
        h.toggles.write(LearningToggles(words: true, style: false))
        #expect(h.learning.style(for: .chat, bundleID: Self.messages) == nil)
    }

    private func seed(_ h: Harness, _ count: Int) {
        for i in 1...count {
            h.store.recordFinalText("Earlier message number \(i)", bundleID: Self.messages, category: .chat)
        }
    }

    private func dictateUnanchored(_ h: Harness) {
        h.learning.didInsert(InsertedDictation(text: Self.original, bundleID: Self.messages, category: .chat))
    }

    @Test func the_twentieth_text_refreshes_the_note() async {
        let generator = FakeStyleGenerator()
        let h = makeHarness(anchors: [.skipped(.noElement)], generator: generator)
        seed(h, 19)
        dictateUnanchored(h)
        #expect(await eventually { h.store.category(.chat).note == "- Uses contractions." })
        #expect(generator.requests.count == 1)
        #expect(generator.requests.first?.texts.count == 20)
        #expect(generator.requests.first?.categoryName == "Chat")
        #expect(generator.requests.first?.model == "test-model")
        #expect(h.store.category(.chat).sinceRefresh == 0)
        #expect(!h.store.category(.chat).noteEditedByUser)
    }

    @Test func an_edited_note_is_not_refreshed() async {
        let generator = FakeStyleGenerator()
        let h = makeHarness(anchors: [.skipped(.noElement)], generator: generator)
        h.store.setNote("Mine", category: .chat, editedByUser: true)
        seed(h, 19)
        dictateUnanchored(h)
        #expect(await eventually { h.store.category(.chat).sinceRefresh == 20 })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(generator.requests.isEmpty)
        #expect(h.store.category(.chat).note == "Mine")
    }

    @Test func a_failed_refresh_keeps_the_note_and_restarts_the_count() async {
        let generator = FakeStyleGenerator()
        generator.result = .failure(LLMError.rateLimited)
        let h = makeHarness(anchors: [.skipped(.noElement)], generator: generator)
        seed(h, 19)
        dictateUnanchored(h)
        #expect(await eventually { generator.requests.count == 1 && h.learning.refreshing.isEmpty })
        #expect(h.store.category(.chat).note == nil)
        #expect(h.store.category(.chat).sinceRefresh == 0)
    }

    @Test func only_one_refresh_runs_per_category() async {
        let generator = FakeStyleGenerator()
        generator.hold = true
        let h = makeHarness(anchors: [.skipped(.noElement)], generator: generator)
        seed(h, 19)
        dictateUnanchored(h)
        #expect(await eventually { generator.requests.count == 1 })
        dictateUnanchored(h)
        #expect(await eventually { h.store.category(.chat).sinceRefresh == 21 })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(generator.requests.count == 1)
        generator.release()
        #expect(await eventually { h.store.category(.chat).note == "- Uses contractions." })
    }

    @Test func an_edit_made_during_a_refresh_wins() async {
        let generator = FakeStyleGenerator()
        generator.hold = true
        let h = makeHarness(anchors: [.skipped(.noElement)], generator: generator)
        seed(h, 19)
        dictateUnanchored(h)
        #expect(await eventually { generator.requests.count == 1 })
        h.store.setNote("Mine", category: .chat, editedByUser: true)
        generator.release()
        #expect(await eventually { h.learning.refreshing.isEmpty })
        #expect(h.store.category(.chat).note == "Mine")
        #expect(h.store.category(.chat).noteEditedByUser)
    }

    @Test func regenerate_replaces_an_edited_note() async {
        let generator = FakeStyleGenerator()
        let h = makeHarness(generator: generator)
        h.store.setNote("Mine", category: .chat, editedByUser: true)
        seed(h, 3)
        await h.learning.regenerate(.chat)?.value
        #expect(h.store.category(.chat).note == "- Uses contractions.")
        #expect(!h.store.category(.chat).noteEditedByUser)
    }

    @Test func regenerate_needs_texts_and_a_generator() {
        let empty = makeHarness(generator: FakeStyleGenerator())
        #expect(empty.learning.regenerate(.chat) == nil)
        let noGenerator = makeHarness()
        seed(noGenerator, 3)
        #expect(noGenerator.learning.regenerate(.chat) == nil)
    }
}
