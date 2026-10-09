import Foundation
import Testing
@testable import voxline

@Suite(.timeLimit(.minutes(1))) @MainActor struct LearningSettingsViewModelTests {

    /// 2026-10-09 12:00 in the current time zone, which the VM formats in.
    static let noon = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 12))!

    struct Harness {
        let vm: LearningSettingsViewModel
        let learning: LearningCoordinator
        let store: LearningStore
        let settings: AppSettings
        let vocabulary: CustomVocabularyStore
        let clock: ManualClock
        let generator: FakeStyleGenerator
    }

    private func makeHarness() -> Harness {
        let suiteName = "voxline-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = AppSettings(defaults: defaults)
        let vocabulary = CustomVocabularyStore(defaults: defaults)
        let store = LearningStore(fileURL: nil, now: { Self.noon })
        let generator = FakeStyleGenerator()
        let learning = LearningCoordinator(
            state: AppState(), store: store, vocabulary: vocabulary,
            reader: FakeCorrectionReader(anchors: [.skipped(.noElement)]),
            dictionary: FakeWordDictionary(),
            toggles: { LearningToggles(words: settings.learnWords, style: settings.learnStyle) },
            generator: generator,
            model: { "test-model" }
        )
        let clock = ManualClock()
        let vm = LearningSettingsViewModel(
            learning: learning, settings: settings, vocabulary: vocabulary,
            sleep: { @MainActor in try await clock.sleep($0) },
            locale: Locale(identifier: "en_US")
        )
        return Harness(vm: vm, learning: learning, store: store, settings: settings,
                       vocabulary: vocabulary, clock: clock, generator: generator)
    }

    @Test func toggles_load_and_write_through() {
        let h = makeHarness()
        #expect(h.vm.learnWords && h.vm.learnStyle)
        h.vm.learnStyle = false
        #expect(!h.settings.learnStyle)
        h.vm.learnWords = false
        #expect(!h.settings.learnWords)
    }

    @Test func an_edit_saves_after_a_second_as_the_users_note() async {
        let h = makeHarness()
        h.vm.editNote("Mine", for: .chat)
        #expect(h.vm.note(for: .chat) == "Mine")
        #expect(h.store.category(.chat).note == nil)
        #expect(await eventually { h.clock.pendingCount == 1 })
        await h.clock.advance(by: .seconds(1))
        #expect(await eventually { h.store.category(.chat).note == "Mine" })
        #expect(h.store.category(.chat).noteEditedByUser)
        #expect(h.vm.drafts.isEmpty)
    }

    @Test func typing_restarts_the_save_timer() async {
        let h = makeHarness()
        h.vm.editNote("M", for: .chat)
        #expect(await eventually { h.clock.pendingCount == 1 })
        await h.clock.advance(by: .milliseconds(500))
        h.vm.editNote("Mine", for: .chat)
        #expect(await eventually { h.clock.pendingCount == 1 })
        await h.clock.advance(by: .milliseconds(600))
        #expect(h.store.category(.chat).note == nil)
        await h.clock.advance(by: .milliseconds(500))
        #expect(await eventually { h.store.category(.chat).note == "Mine" })
    }

    @Test func a_long_edit_is_cut_to_the_note_cap() {
        let h = makeHarness()
        h.vm.editNote(String(repeating: "n", count: 700), for: .chat)
        h.vm.commitAllDrafts()
        #expect(h.store.category(.chat).note?.utf16.count == LearningStore.noteCap)
    }

    @Test func commitAllDrafts_saves_now() {
        let h = makeHarness()
        h.vm.editNote("Mine", for: .email)
        h.vm.commitAllDrafts()
        #expect(h.store.category(.email).note == "Mine")
        #expect(h.vm.drafts.isEmpty)
    }

    @Test func status_lines() {
        let h = makeHarness()
        #expect(h.vm.status(for: .chat) == "Appears after 20 dictations (0 so far)")
        for i in 1...3 { h.store.recordFinalText("Message number \(i)", bundleID: nil, category: .chat) }
        #expect(h.vm.status(for: .chat) == "Appears after 20 dictations (3 so far)")
        h.store.setNote("- Short.", category: .chat, editedByUser: false)
        #expect(h.vm.status(for: .chat) == "Learned from 3 dictations · updated Oct 9")
        h.store.setNote("Mine", category: .chat, editedByUser: true)
        #expect(h.vm.status(for: .chat) == "Edited by you — automatic updates paused")
    }

    @Test func regenerate_needs_three_texts_and_confirms_over_an_edit() {
        let h = makeHarness()
        for i in 1...2 { h.store.recordFinalText("Message number \(i)", bundleID: nil, category: .chat) }
        #expect(!h.vm.canRegenerate(.chat))
        h.store.recordFinalText("Message number 3", bundleID: nil, category: .chat)
        #expect(h.vm.canRegenerate(.chat))
        #expect(!h.vm.needsRegenerateConfirmation(.chat))
        h.vm.editNote("Mine", for: .chat)
        #expect(h.vm.needsRegenerateConfirmation(.chat))
    }

    @Test func regenerate_drops_a_pending_edit_and_replaces_the_note() async {
        let h = makeHarness()
        for i in 1...3 { h.store.recordFinalText("Message number \(i)", bundleID: nil, category: .chat) }
        h.vm.editNote("Mine", for: .chat)
        await h.vm.regenerate(.chat)?.value
        #expect(h.vm.drafts.isEmpty)
        #expect(h.store.category(.chat).note == "- Uses contractions.")
        #expect(h.vm.note(for: .chat) == "- Uses contractions.")
    }

    @Test func reset_clears_drafts_learning_and_learned_words() {
        let h = makeHarness()
        h.vocabulary.save(["Cursor"])
        h.vocabulary.addLearned("Argmax")
        #expect(h.vm.learnedWordCount == 1)
        h.store.recordFinalText("Message number 1", bundleID: nil, category: .chat)
        h.vm.editNote("Mine", for: .chat)
        h.vm.resetLearning()
        #expect(h.vm.drafts.isEmpty)
        #expect(h.store.data == LearningData())
        #expect(h.vocabulary.load() == ["Cursor"])
    }

    @Test func toggling_style_off_drops_a_refresh_in_flight() async {
        let h = makeHarness()
        for i in 1...3 { h.store.recordFinalText("Message number \(i)", bundleID: nil, category: .chat) }
        h.generator.hold = true
        let task = h.vm.regenerate(.chat)
        #expect(!h.vm.canRegenerate(.chat))
        #expect(h.vm.status(for: .chat) == "Updating…")
        h.vm.learnStyle = false
        h.generator.release()
        await task?.value
        #expect(h.store.category(.chat).note == nil)
        #expect(h.vm.canRegenerate(.chat))
    }

    @Test func toggling_both_off_cancels_the_open_window() async {
        let h = makeHarness()
        h.learning.didInsert(InsertedDictation(text: "Hello there", bundleID: nil, category: .chat))
        h.vm.learnWords = false
        h.vm.learnStyle = false
        h.learning.captureWillStart()
        #expect(h.store.category(.chat).recentTexts.isEmpty)
    }

    @Test func flushing_drafts_on_disappear_saves_them() {
        let h = makeHarness()
        h.vm.editNote("Typed", for: .chat)
        h.vm.commitAllDrafts()
        #expect(h.store.category(.chat).note == "Typed")
        #expect(h.clock.pendingCount == 0)
    }
}
