import Testing
import Foundation
@testable import voxline

@Suite @MainActor struct SettingsStatusViewModelTests {

    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "voxline-status-test-\(UUID().uuidString)")!
    }

    private func keychain() -> Keychain {
        Keychain(service: "com.voxline.voxline.test.\(UUID().uuidString)")
    }

    /// Build (general, keys, status) with the given configuration. Caller is
    /// responsible for `try? kc.deleteAll()` cleanup if a key was set.
    private func makeFixtures(
        provider: LLMProvider = .anthropic,
        model: WhisperModel = .smallEn,
        anthropicKey: String = "sk-ant-good",
        openaiKey: String = "",
        deviceLabel: String = "MacBook Mic",
        deviceUID: String? = "uid-1",
        modelCached: Bool = true
    ) throws -> (general: GeneralSettingsViewModel, keys: APIKeysSettingsViewModel, status: SettingsStatusViewModel, kc: Keychain) {
        let kc = keychain()
        if !anthropicKey.isEmpty {
            try kc.set(anthropicKey, forKey: Keychain.Account.anthropic)
        }
        if !openaiKey.isEmpty {
            try kc.set(openaiKey, forKey: Keychain.Account.openai)
        }
        var settings = AppSettings(defaults: defaults())
        settings.whisperModel = model
        settings.llmProvider = provider
        settings.audioInputDeviceUID = deviceUID
        let general = GeneralSettingsViewModel(
            settings: settings,
            applier: NoopApplier(),
            deviceEnumerator: { [AudioDevice(uid: "uid-1", name: deviceLabel, isDefault: true)] }
        )
        let keys = APIKeysSettingsViewModel(keychain: kc)
        let status = SettingsStatusViewModel(
            general: general,
            keys: keys,
            isModelCached: { _ in modelCached }
        )
        return (general, keys, status, kc)
    }

    @Test func ready_when_provider_key_saved_and_model_cached_and_mic_present() throws {
        let f = try makeFixtures()
        defer { try? f.kc.deleteAll() }
        #expect(f.status.isReady == true)
        #expect(f.status.providerChipShowsCheck == true)
        #expect(f.status.modelChipShowsCheck == true)
    }

    @Test func setup_needed_when_active_provider_key_missing() throws {
        let f = try makeFixtures(provider: .openai, openaiKey: "")
        defer { try? f.kc.deleteAll() }
        #expect(f.status.isReady == false)
        #expect(f.status.providerChipShowsCheck == false)
    }

    @Test func setup_needed_when_model_not_cached() throws {
        let f = try makeFixtures(modelCached: false)
        defer { try? f.kc.deleteAll() }
        #expect(f.status.isReady == false)
        #expect(f.status.modelChipShowsCheck == false)
    }

    @Test func mic_chip_uses_selected_device_label() throws {
        let f = try makeFixtures(deviceLabel: "Studio Mic")
        defer { try? f.kc.deleteAll() }
        #expect(f.status.micChipText.contains("Studio Mic"))
    }

    @Test func setup_needed_when_saved_mic_uid_is_disconnected() throws {
        // Saved UID points to a device that isn't in the current device list.
        let f = try makeFixtures(deviceUID: "ghost-uid")
        defer { try? f.kc.deleteAll() }
        #expect(f.status.isReady == false)
    }

    @Test func setup_needed_when_no_devices_and_no_uid() throws {
        let kc = keychain()
        try kc.set("sk-ant-good", forKey: Keychain.Account.anthropic)
        defer { try? kc.deleteAll() }
        var settings = AppSettings(defaults: defaults())
        settings.audioInputDeviceUID = nil
        settings.llmProvider = .anthropic
        let general = GeneralSettingsViewModel(
            settings: settings,
            applier: NoopApplier(),
            deviceEnumerator: { [] }   // no mics at all
        )
        let keys = APIKeysSettingsViewModel(keychain: kc)
        let status = SettingsStatusViewModel(
            general: general,
            keys: keys,
            isModelCached: { _ in true }
        )
        #expect(status.isReady == false)
    }
}

private struct NoopApplier: GeneralSettingsApplier {
    func apply(_ snapshot: GeneralSettingsSnapshot) {}
}
