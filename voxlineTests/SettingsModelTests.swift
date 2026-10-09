import Foundation
import Testing
@testable import voxline

@Suite @MainActor struct SettingsModelTests {

    @Test func refresh_reloads_settings_changed_elsewhere() throws {
        let suiteName = "voxline-settings-model-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        let general = GeneralSettingsViewModel(
            settings: settings,
            onApply: { _ in },
            deviceEnumerator: { [] }
        )
        let learning = LearningCoordinator(
            state: AppState(),
            store: LearningStore(fileURL: nil, now: { Date() }),
            vocabulary: CustomVocabularyStore(defaults: defaults),
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
            engineReadiness: { _ in .ready }
        )
        var elsewhere = AppSettings(defaults: defaults)
        elsewhere.playHotkeySounds = !general.playHotkeySounds
        let expected = elsewhere.playHotkeySounds

        model.refresh()

        #expect(model.general.playHotkeySounds == expected)
    }
}
