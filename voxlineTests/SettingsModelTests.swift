import Foundation
import Testing
@testable import voxline

@Suite @MainActor struct SettingsModelTests {

    private struct Harness {
        let model: SettingsModel
        let general: GeneralSettingsViewModel
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
        let model = SettingsModel(
            general: general,
            apiKeys: APIKeysSettingsViewModel(keychain: InMemoryKeychain()),
            command: CommandSettingsViewModel(chords: { general.chords }, onChange: {}),
            meetings: MeetingSettingsViewModel(settings: settings, presets: { [] }, chords: { general.chords }, onChange: {}),
            vocabularyStore: CustomVocabularyStore(defaults: defaults),
            engineReadiness: { _ in .ready }
        )
        return Harness(model: model, general: general, defaults: defaults)
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
}
