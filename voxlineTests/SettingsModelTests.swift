import Foundation
import Testing
@testable import voxline

@Suite @MainActor struct SettingsModelTests {

    private struct Harness {
        let model: SettingsModel
        let general: GeneralSettingsViewModel
        let learning: LearningCoordinator
        let vocabulary: CustomVocabularyStore
        let defaults: UserDefaults
    }

    private func makeHarness(suiteName: String) -> Harness {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = AppSettings(defaults: defaults)
        let general = GeneralSettingsViewModel(
            settings: settings,
            onApply: { _ in },
            deviceEnumerator: { [] }
        )
        let vocabulary = CustomVocabularyStore(defaults: defaults)
        let learning = LearningCoordinator(
            state: AppState(),
            store: LearningStore(fileURL: nil, now: { Date() }),
            vocabulary: vocabulary,
            reader: FakeCorrectionReader(anchors: [.skipped(.noElement)]),
            dictionary: FakeWordDictionary(),
            toggles: { LearningToggles(words: false, style: false) },
            generator: FakeStyleGenerator(),
            model: { "test-model" }
        )
        let model = SettingsModel(
            general: general,
            apiKeys: APIKeysSettingsViewModel(keychain: InMemoryKeychain()),
            command: CommandSettingsViewModel(chords: { general.chords }, onChange: {}),
            meetings: MeetingSettingsViewModel(settings: settings, presets: { [] }, chords: { general.chords }, onChange: {}),
            learning: learning,
            vocabularyStore: vocabulary,
            engineReadiness: { _ in .ready }
        )
        return Harness(model: model, general: general, learning: learning, vocabulary: vocabulary, defaults: defaults)
    }

    @Test func refresh_reloads_settings_changed_elsewhere() throws {
        let suiteName = "voxline-settings-model-\(UUID().uuidString)"
        let h = makeHarness(suiteName: suiteName)
        defer { h.defaults.removePersistentDomain(forName: suiteName) }
        var elsewhere = AppSettings(defaults: h.defaults)
        elsewhere.playHotkeySounds = !h.general.playHotkeySounds
        let expected = elsewhere.playHotkeySounds

        h.model.refresh()

        #expect(h.model.general.playHotkeySounds == expected)
    }

    @Test func removing_a_learned_term_stops_learning_it() throws {
        let suiteName = "voxline-settings-model-\(UUID().uuidString)"
        let h = makeHarness(suiteName: suiteName)
        defer { h.defaults.removePersistentDomain(forName: suiteName) }
        #expect(h.vocabulary.addLearned("Kubernetes"))
        h.model.vocabulary.reload()

        h.model.vocabulary.remove("Kubernetes")

        #expect(h.learning.store.isRejected("Kubernetes"))
        #expect(!h.model.vocabulary.terms.contains("Kubernetes"))
    }

    @Test func adding_a_term_by_hand_lets_learning_have_it_again() throws {
        let suiteName = "voxline-settings-model-\(UUID().uuidString)"
        let h = makeHarness(suiteName: suiteName)
        defer { h.defaults.removePersistentDomain(forName: suiteName) }
        h.learning.store.reject(["Kubernetes"])

        h.model.vocabulary.draft = "Kubernetes"
        h.model.vocabulary.addTerm()

        #expect(!h.learning.store.isRejected("Kubernetes"))
        #expect(h.vocabulary.load().contains("Kubernetes"))
    }
}
