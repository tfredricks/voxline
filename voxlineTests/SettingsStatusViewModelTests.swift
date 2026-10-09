import Testing
import Foundation
@testable import voxline

@Suite @MainActor struct SettingsStatusViewModelTests {

    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "voxline-status-test-\(UUID().uuidString)")!
    }

    private func keychain() -> InMemoryKeychain {
        InMemoryKeychain()
    }

    /// Build (general, keys, status) with the given configuration. Readiness
    /// is not checked yet; call `status.refreshEngineReadiness()`.
    private func makeFixtures(
        provider: LLMProvider = .anthropic,
        engine: EngineID = .whisperKit,
        model: WhisperModel = .smallEn,
        anthropicKey: String = "sk-ant-good",
        openaiKey: String = "",
        deviceLabel: String = "MacBook Mic",
        deviceUID: String? = "uid-1",
        readiness: @escaping @MainActor (EngineID) async -> EngineReadiness? = { _ in .ready }
    ) throws -> (general: GeneralSettingsViewModel, keys: APIKeysSettingsViewModel, status: SettingsStatusViewModel, kc: InMemoryKeychain) {
        let kc = keychain()
        if !anthropicKey.isEmpty {
            try kc.set(anthropicKey, forKey: KeychainAccount.anthropic)
        }
        if !openaiKey.isEmpty {
            try kc.set(openaiKey, forKey: KeychainAccount.openai)
        }
        var settings = AppSettings(defaults: defaults())
        settings.transcriptionEngine = engine
        settings.whisperModel = model
        settings.llmProvider = provider
        settings.audioInputDeviceUID = deviceUID
        let general = GeneralSettingsViewModel(
            settings: settings,
            onApply: { _ in },
            deviceEnumerator: { [AudioDevice(uid: "uid-1", name: deviceLabel, isDefault: true)] }
        )
        let keys = APIKeysSettingsViewModel(keychain: kc)
        let status = SettingsStatusViewModel(general: general, keys: keys, engineReadiness: readiness)
        return (general, keys, status, kc)
    }

    @Test func ready_when_provider_key_saved_and_engine_ready_and_mic_present() async throws {
        let f = try makeFixtures()
        await f.status.refreshEngineReadiness()
        #expect(f.status.isReady == true)
        #expect(f.status.providerChipShowsCheck == true)
        #expect(f.status.engineChipShowsCheck == true)
    }

    @Test func setup_needed_until_readiness_is_checked() throws {
        let f = try makeFixtures()
        #expect(f.status.isReady == false)
        #expect(f.status.engineChipShowsCheck == false)
    }

    @Test func setup_needed_when_active_provider_key_missing() async throws {
        let f = try makeFixtures(provider: .openai, openaiKey: "")
        await f.status.refreshEngineReadiness()
        #expect(f.status.isReady == false)
        #expect(f.status.providerChipShowsCheck == false)
    }

    @Test func setup_needed_when_engine_needs_preparation() async throws {
        let f = try makeFixtures(readiness: { _ in .needsPreparation(downloadMB: 466) })
        await f.status.refreshEngineReadiness()
        #expect(f.status.isReady == false)
        #expect(f.status.engineChipShowsCheck == false)
        #expect(f.status.engineUnavailableReason == nil)
    }

    @Test func setup_needed_and_reason_shown_when_engine_unavailable() async throws {
        let reason = "Apple Speech doesn't support this Mac's language."
        let f = try makeFixtures(engine: .apple, readiness: { _ in .unavailable(reason) })
        await f.status.refreshEngineReadiness()
        #expect(f.status.isReady == false)
        #expect(f.status.engineChipShowsCheck == false)
        #expect(f.status.engineUnavailableReason == reason)
    }

    @Test func setup_needed_when_engines_are_not_built_yet() async throws {
        let f = try makeFixtures(readiness: { _ in nil })
        await f.status.refreshEngineReadiness()
        #expect(f.status.isReady == false)
        #expect(f.status.engineChipShowsCheck == false)
    }

    @Test func readiness_is_checked_for_the_selected_engine() async throws {
        var asked: [EngineID] = []
        let f = try makeFixtures(engine: .apple, readiness: { id in asked.append(id); return .ready })
        await f.status.refreshEngineReadiness()
        f.general.engine = .whisperKit
        await f.status.refreshEngineReadiness()
        #expect(asked == [.apple, .whisperKit])
    }

    @Test func switching_engines_hides_the_check_until_rechecked() async throws {
        let f = try makeFixtures(engine: .apple)
        await f.status.refreshEngineReadiness()
        #expect(f.status.engineChipShowsCheck == true)

        f.general.engine = .whisperKit
        #expect(f.status.engineChipShowsCheck == false)

        await f.status.refreshEngineReadiness()
        #expect(f.status.engineChipShowsCheck == true)
    }

    @Test func switching_whisper_models_hides_the_check_until_rechecked() async throws {
        let f = try makeFixtures(engine: .whisperKit, model: .smallEn)
        await f.status.refreshEngineReadiness()
        f.general.whisperModel = .largeV3Turbo
        #expect(f.status.engineChipShowsCheck == false)
    }

    @Test func saving_an_openai_key_rechecks_the_openai_engine() async throws {
        var keySaved = false
        let f = try makeFixtures(engine: .openAIRealtime, readiness: { _ in
            keySaved ? .ready : .unavailable("Add an OpenAI API key in Settings → General → Recognition to use OpenAI transcription.")
        })
        await f.status.refreshEngineReadiness()
        #expect(f.status.engineChipShowsCheck == false)
        let before = f.status.readinessKey

        f.keys.openaiKey = "sk-openai-new"
        f.keys.commitOpenAI()
        keySaved = true
        #expect(f.status.readinessKey != before)
        #expect(f.status.engineUnavailableReason == nil)

        await f.status.refreshEngineReadiness()
        #expect(f.status.engineChipShowsCheck == true)
    }

    @Test func saving_an_openai_key_keeps_an_on_device_check() async throws {
        let f = try makeFixtures(engine: .whisperKit)
        await f.status.refreshEngineReadiness()
        let before = f.status.readinessKey

        f.keys.openaiKey = "sk-openai-new"
        f.keys.commitOpenAI()
        #expect(f.status.readinessKey == before)
        #expect(f.status.engineChipShowsCheck == true)
    }

    @Test func a_superseded_check_does_not_overwrite_a_newer_one() async throws {
        let gate = ReadinessGate()
        let f = try makeFixtures(engine: .apple, readiness: { id in
            id == .apple ? await gate.wait() : .ready
        })
        let stale = Task { await f.status.refreshEngineReadiness() }
        await gate.waitUntilBlocked()
        f.general.engine = .whisperKit
        await f.status.refreshEngineReadiness()
        #expect(f.status.engineChipShowsCheck == true)

        gate.release(.needsPreparation(downloadMB: nil))
        await stale.value
        #expect(f.status.engineChipShowsCheck == true)
    }

    @Test func engine_chip_names_the_whisper_model_only_for_whisper() throws {
        #expect(try makeFixtures(engine: .whisperKit, model: .smallEn).status.engineChipText == WhisperModel.smallEn.displayName)
        #expect(try makeFixtures(engine: .apple).status.engineChipText == "Apple Speech")
        #expect(try makeFixtures(engine: .openAIRealtime).status.engineChipText == "OpenAI")
    }

    @Test func mic_chip_uses_selected_device_label() throws {
        let f = try makeFixtures(deviceLabel: "Studio Mic")
        #expect(f.status.micChipText.contains("Studio Mic"))
    }

    @Test func setup_needed_when_saved_mic_uid_is_disconnected() async throws {
        // Saved UID points to a device that isn't in the current device list.
        let f = try makeFixtures(deviceUID: "ghost-uid")
        await f.status.refreshEngineReadiness()
        #expect(f.status.isReady == false)
    }

    @Test func setup_needed_when_no_devices_and_no_uid() async throws {
        let kc = keychain()
        try kc.set("sk-ant-good", forKey: KeychainAccount.anthropic)
        var settings = AppSettings(defaults: defaults())
        settings.audioInputDeviceUID = nil
        settings.llmProvider = .anthropic
        let general = GeneralSettingsViewModel(
            settings: settings,
            onApply: { _ in },
            deviceEnumerator: { [] }   // no mics at all
        )
        let keys = APIKeysSettingsViewModel(keychain: kc)
        let status = SettingsStatusViewModel(general: general, keys: keys, engineReadiness: { _ in .ready })
        await status.refreshEngineReadiness()
        #expect(status.isReady == false)
    }

    @Test func no_issues_when_everything_is_ready() async throws {
        let f = try makeFixtures()
        await f.status.refreshEngineReadiness()
        #expect(f.status.issues.isEmpty)
    }

    @Test func unchecked_readiness_is_not_an_issue() async throws {
        let f = try makeFixtures(readiness: { _ in nil })
        await f.status.refreshEngineReadiness()
        #expect(f.status.issues.isEmpty)
    }

    @Test func missing_provider_key_is_an_ai_provider_issue() async throws {
        let f = try makeFixtures(provider: .openai, openaiKey: "")
        await f.status.refreshEngineReadiness()
        #expect(f.status.issues == [SetupIssue(text: "No OpenAI API key", page: .aiProvider)])
    }

    @Test func unavailable_engine_reason_is_a_dictation_issue() async throws {
        let reason = "Apple Speech doesn't support this Mac's language."
        let f = try makeFixtures(engine: .apple, readiness: { _ in .unavailable(reason) })
        await f.status.refreshEngineReadiness()
        #expect(f.status.issues == [SetupIssue(text: reason, page: .dictation)])
    }

    @Test func whisper_download_issue_names_the_model_and_size() async throws {
        let f = try makeFixtures(engine: .whisperKit, readiness: { _ in .needsPreparation(downloadMB: 466) })
        await f.status.refreshEngineReadiness()
        #expect(f.status.issues == [SetupIssue(text: "The Whisper model needs a one-time download (466 MB)", page: .dictation)])
    }

    @Test func download_issue_omits_an_unknown_size() async throws {
        let f = try makeFixtures(engine: .apple, readiness: { _ in .needsPreparation(downloadMB: nil) })
        await f.status.refreshEngineReadiness()
        #expect(f.status.issues == [SetupIssue(text: "Apple Speech needs a one-time download", page: .dictation)])
    }

    @Test func missing_microphone_is_a_dictation_issue() async throws {
        let f = try makeFixtures(deviceUID: "ghost-uid")
        await f.status.refreshEngineReadiness()
        #expect(f.status.issues == [SetupIssue(text: "Microphone not found", page: .dictation)])
    }

    @Test func needs_setup_maps_issues_to_their_pages() async throws {
        let f = try makeFixtures(provider: .openai, openaiKey: "")
        await f.status.refreshEngineReadiness()
        #expect(f.status.needsSetup(.aiProvider))
        #expect(!f.status.needsSetup(.dictation))
        #expect(!f.status.needsSetup(.home))
    }
}

/// Holds one readiness check open until the test releases it.
@MainActor
private final class ReadinessGate {
    private var pending: CheckedContinuation<EngineReadiness?, Never>?
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async -> EngineReadiness? {
        await withCheckedContinuation { continuation in
            pending = continuation
            blockedWaiters.forEach { $0.resume() }
            blockedWaiters.removeAll()
        }
    }

    func waitUntilBlocked() async {
        if pending != nil { return }
        await withCheckedContinuation { blockedWaiters.append($0) }
    }

    func release(_ readiness: EngineReadiness?) {
        pending?.resume(returning: readiness)
        pending = nil
    }
}
