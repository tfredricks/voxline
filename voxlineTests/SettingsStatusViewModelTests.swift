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
        devices: DeviceList? = nil,
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
            deviceEnumerator: devices.map { list in { list.devices } }
                ?? { [AudioDevice(uid: "uid-1", name: deviceLabel, isDefault: true)] }
        )
        let keys = APIKeysSettingsViewModel(keychain: kc)
        let status = SettingsStatusViewModel(general: general, keys: keys, engineReadiness: readiness)
        return (general, keys, status, kc)
    }

    @Test func readiness_is_checked_for_the_selected_engine() async throws {
        var asked: [EngineID] = []
        let f = try makeFixtures(engine: .apple, readiness: { id in asked.append(id); return .ready })
        await f.status.refreshEngineReadiness()
        f.general.engine = .whisperKit
        await f.status.refreshEngineReadiness()
        #expect(asked == [.apple, .whisperKit])
    }

    @Test func switching_engines_drops_the_old_check() async throws {
        let f = try makeFixtures(engine: .apple, readiness: { id in
            id == .apple ? .ready : .needsPreparation(downloadMB: nil)
        })
        await f.status.refreshEngineReadiness()
        #expect(f.status.issues.isEmpty)

        f.general.engine = .whisperKit
        #expect(f.status.issues.isEmpty)

        await f.status.refreshEngineReadiness()
        #expect(f.status.issues.contains { $0.page == .dictation })
    }

    @Test func switching_whisper_models_drops_the_old_check() async throws {
        let f = try makeFixtures(engine: .whisperKit, model: .smallEn, readiness: { _ in .needsPreparation(downloadMB: nil) })
        await f.status.refreshEngineReadiness()
        #expect(f.status.issues.contains { $0.page == .dictation })

        f.general.whisperModel = .largeV3Turbo
        #expect(f.status.issues.isEmpty)
    }

    @Test func saving_an_openai_key_rechecks_the_openai_engine() async throws {
        var checks = 0
        let f = try makeFixtures(engine: .openAIRealtime, readiness: { _ in
            checks += 1
            return checks == 1
                ? .unavailable(OpenAIRealtimeEngine.missingKeyReason)
                : .needsPreparation(downloadMB: nil)
        })
        await f.status.refreshEngineReadiness()
        #expect(f.status.issues.contains { $0.text == OpenAIRealtimeEngine.missingKeyReason })
        let before = f.status.readinessKey

        f.keys.openaiKey = "sk-openai-new"
        f.keys.commitOpenAI()
        #expect(f.status.readinessKey != before)
        #expect(!f.status.issues.contains { $0.page == .dictation })

        await f.status.refreshEngineReadiness()
        #expect(checks == 2)
        #expect(f.status.issues == [SetupIssue(text: "OpenAI needs a one-time download", page: .dictation)])
    }

    @Test func saving_an_openai_key_keeps_an_on_device_check() async throws {
        let f = try makeFixtures(engine: .whisperKit)
        await f.status.refreshEngineReadiness()
        let before = f.status.readinessKey

        f.keys.openaiKey = "sk-openai-new"
        f.keys.commitOpenAI()
        #expect(f.status.readinessKey == before)
        #expect(f.status.issues.isEmpty)
    }

    @Test func a_superseded_check_does_not_overwrite_a_newer_one() async throws {
        let gate = ReadinessGate()
        let f = try makeFixtures(engine: .apple, readiness: { id in
            id == .apple ? await gate.wait() : .needsPreparation(downloadMB: nil)
        })
        let stale = Task { await f.status.refreshEngineReadiness() }
        await gate.waitUntilBlocked()
        f.general.engine = .whisperKit
        await f.status.refreshEngineReadiness()
        #expect(f.status.issues.contains { $0.page == .dictation })

        gate.release(.ready)
        await stale.value
        #expect(f.status.issues.contains { $0.page == .dictation })
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
        #expect(status.issues == [SetupIssue(text: "Microphone not found", page: .dictation)])
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

    @Test func saving_the_provider_key_clears_the_ai_provider_issue() async throws {
        let f = try makeFixtures(provider: .anthropic, anthropicKey: "")
        await f.status.refreshEngineReadiness()
        #expect(f.status.issues.contains { $0.page == .aiProvider })

        f.keys.anthropicKey = "sk-ant-new"
        f.keys.commitAnthropic()
        #expect(!f.status.issues.contains { $0.page == .aiProvider })
        #expect(f.status.issues.isEmpty)
    }

    @Test func reconnecting_the_microphone_clears_the_microphone_issue() async throws {
        let mics = DeviceList()
        let f = try makeFixtures(deviceUID: "uid-1", devices: mics)
        await f.status.refreshEngineReadiness()
        #expect(f.status.issues == [SetupIssue(text: "Microphone not found", page: .dictation)])

        mics.devices = [AudioDevice(uid: "uid-1", name: "USB Mic", isDefault: true)]
        f.general.refreshDevices()
        #expect(!f.status.issues.contains { $0.text == "Microphone not found" })
        #expect(f.status.issues.isEmpty)
    }

    @Test func openai_engine_and_provider_without_a_key_report_only_the_ai_provider_issue() async throws {
        let f = try makeFixtures(
            provider: .openai,
            engine: .openAIRealtime,
            anthropicKey: "",
            openaiKey: "",
            readiness: { _ in .unavailable(OpenAIRealtimeEngine.missingKeyReason) }
        )
        await f.status.refreshEngineReadiness()
        #expect(f.status.issues == [SetupIssue(text: "No OpenAI API key", page: .aiProvider)])
        #expect(!f.status.issues.contains { $0.page == .dictation })
    }

    @Test func openai_engine_without_a_key_under_another_provider_is_a_dictation_issue() async throws {
        let f = try makeFixtures(
            provider: .anthropic,
            engine: .openAIRealtime,
            openaiKey: "",
            readiness: { _ in .unavailable(OpenAIRealtimeEngine.missingKeyReason) }
        )
        await f.status.refreshEngineReadiness()
        #expect(f.status.issues == [SetupIssue(text: OpenAIRealtimeEngine.missingKeyReason, page: .dictation)])
    }
}

/// Input devices the test can change between enumerations.
private final class DeviceList {
    var devices: [AudioDevice] = []
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
