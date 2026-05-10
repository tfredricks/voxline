import Testing
import Foundation
@testable import voxline

@Suite @MainActor struct GeneralSettingsViewModelTests {

    private func defaults() -> UserDefaults {
        let n = "voxline-test-\(UUID().uuidString)"
        return UserDefaults(suiteName: n)!
    }

    @Test func loads_current_values_on_init() {
        var settings = AppSettings(defaults: defaults())
        let chord = HotkeyChord(modifierA: .leftCommand, modifierB: .leftShift)
        settings.hotkeyChord = chord
        settings.audioInputDeviceUID = "MyMic"
        settings.whisperModel = .smallEn
        settings.playHotkeySounds = false
        settings.llmProvider = .openai

        let vm = GeneralSettingsViewModel(settings: settings, applier: NoopApplier())
        #expect(vm.chord == chord)
        #expect(vm.audioInputDeviceUID == "MyMic")
        #expect(vm.whisperModel == .smallEn)
        #expect(vm.playHotkeySounds == false)
        #expect(vm.provider == .openai)
    }

    @Test func mutations_persist_and_call_applier_immediately() {
        let d = defaults()
        let settings = AppSettings(defaults: d)
        let applier = RecordingApplier()
        let vm = GeneralSettingsViewModel(settings: settings, applier: applier)

        let chord = HotkeyChord(modifierA: .rightCommand, modifierB: .rightShift)
        vm.chord = chord
        #expect(applier.applied?.chord == chord)
        #expect(AppSettings(defaults: d).hotkeyChord == chord)

        vm.audioInputDeviceUID = "NewMic"
        #expect(applier.applied?.audioInputDeviceUID == "NewMic")
        #expect(AppSettings(defaults: d).audioInputDeviceUID == "NewMic")

        vm.whisperModel = .smallEn
        #expect(applier.applied?.whisperModel == .smallEn)
        #expect(AppSettings(defaults: d).whisperModel == .smallEn)

        vm.playHotkeySounds = false
        #expect(applier.applied?.playHotkeySounds == false)
        #expect(AppSettings(defaults: d).playHotkeySounds == false)

        #expect(applier.applied?.provider == .anthropic)
    }

    @Test func init_does_not_call_applier() {
        var settings = AppSettings(defaults: defaults())
        settings.hotkeyChord = HotkeyChord(modifierA: .leftCommand, modifierB: .rightOption)
        let applier = RecordingApplier()
        _ = GeneralSettingsViewModel(settings: settings, applier: applier)
        #expect(applier.applied == nil)
    }

    @Test func device_rows_includes_disconnected_marker_when_saved_uid_is_absent() {
        var settings = AppSettings(defaults: defaults())
        settings.audioInputDeviceUID = "GhostMic"
        let vm = GeneralSettingsViewModel(
            settings: settings,
            applier: NoopApplier(),
            deviceEnumerator: { [] }   // no devices present
        )
        let rows = vm.deviceRows
        #expect(rows.contains { $0.uid == "GhostMic" && $0.label.contains("disconnected") })
    }

    @Test func device_rows_omits_disconnected_marker_when_uid_is_present_in_device_list() {
        var settings = AppSettings(defaults: defaults())
        settings.audioInputDeviceUID = "MicA"
        let stubDevices = [AudioDevice(uid: "MicA", name: "Mic A", isDefault: false)]
        let vm = GeneralSettingsViewModel(
            settings: settings,
            applier: NoopApplier(),
            deviceEnumerator: { stubDevices }
        )
        let rows = vm.deviceRows
        #expect(rows.contains { $0.uid == "MicA" && !$0.label.contains("disconnected") })
        #expect(rows.allSatisfy { !$0.label.contains("disconnected") || $0.uid != "MicA" })
    }

    @Test func refresh_devices_picks_up_new_enumerator_output() {
        var nextDevices: [AudioDevice] = []
        let settings = AppSettings(defaults: defaults())
        let vm = GeneralSettingsViewModel(
            settings: settings,
            applier: NoopApplier(),
            deviceEnumerator: { nextDevices }
        )
        #expect(vm.devices.isEmpty)

        nextDevices = [AudioDevice(uid: "MicNew", name: "New Mic", isDefault: true)]
        vm.refreshDevices()
        #expect(vm.devices == [AudioDevice(uid: "MicNew", name: "New Mic", isDefault: true)])
    }

    @Test func reset_restores_spec_defaults_and_calls_applier_once() {
        var settings = AppSettings(defaults: defaults())
        settings.hotkeyChord = HotkeyChord(modifierA: .rightCommand, modifierB: .rightShift)
        settings.audioInputDeviceUID = "MicX"
        settings.whisperModel = .smallEn
        settings.playHotkeySounds = false
        settings.llmProvider = .openai

        let applier = RecordingApplier()
        let vm = GeneralSettingsViewModel(settings: settings, applier: applier)
        vm.resetToDefaults()

        #expect(vm.chord == .default)
        #expect(vm.audioInputDeviceUID == nil)
        #expect(vm.whisperModel == .default)
        #expect(vm.playHotkeySounds == true)
        #expect(applier.applied?.chord == .default)
        #expect(applier.applied?.whisperModel == .default)
        #expect(applier.applied?.playHotkeySounds == true)
        #expect(applier.applied?.audioInputDeviceUID == nil)
        #expect(vm.provider == .anthropic)
        #expect(applier.applied?.provider == .anthropic)
    }

    @Test func provider_change_persists_and_calls_applier() {
        let d = defaults()
        let settings = AppSettings(defaults: d)
        let applier = RecordingApplier()
        let vm = GeneralSettingsViewModel(settings: settings, applier: applier)

        vm.provider = .openai
        #expect(applier.applied?.provider == .openai)
        #expect(AppSettings(defaults: d).llmProvider == .openai)
    }

    @Test func launch_at_login_initialized_from_login_item_status() {
        let backend = StubLoginBackend(status: .enabled)
        let svc = LoginItemService(backend: backend)
        let vm = GeneralSettingsViewModel(
            settings: AppSettings(defaults: defaults()),
            applier: NoopApplier(),
            loginItemService: svc
        )
        #expect(vm.launchAtLogin == true)
        #expect(vm.loginItemStatus == .enabled)
    }

    @Test func launch_at_login_disabled_when_not_registered() {
        let backend = StubLoginBackend(status: .notRegistered)
        let svc = LoginItemService(backend: backend)
        let vm = GeneralSettingsViewModel(
            settings: AppSettings(defaults: defaults()),
            applier: NoopApplier(),
            loginItemService: svc
        )
        #expect(vm.launchAtLogin == false)
        #expect(vm.loginItemStatus == .disabled)
    }

    @Test func toggling_launch_at_login_to_true_calls_register() throws {
        let backend = StubLoginBackend(status: .notRegistered)
        let svc = LoginItemService(backend: backend)
        let vm = GeneralSettingsViewModel(
            settings: AppSettings(defaults: defaults()),
            applier: NoopApplier(),
            loginItemService: svc
        )
        vm.launchAtLogin = true
        #expect(backend.registerCount == 1)
        #expect(vm.loginItemStatus == .enabled)
        #expect(vm.launchAtLogin == true)
    }

    @Test func toggling_launch_at_login_to_false_calls_unregister() throws {
        let backend = StubLoginBackend(status: .enabled)
        let svc = LoginItemService(backend: backend)
        let vm = GeneralSettingsViewModel(
            settings: AppSettings(defaults: defaults()),
            applier: NoopApplier(),
            loginItemService: svc
        )
        vm.launchAtLogin = false
        #expect(backend.unregisterCount == 1)
        #expect(vm.loginItemStatus == .disabled)
        #expect(vm.launchAtLogin == false)
    }

    @Test func register_yielding_requires_approval_keeps_toggle_off() {
        let backend = StubLoginBackend(status: .notRegistered)
        backend.registerYields = .requiresApproval
        let svc = LoginItemService(backend: backend)
        let vm = GeneralSettingsViewModel(
            settings: AppSettings(defaults: defaults()),
            applier: NoopApplier(),
            loginItemService: svc
        )
        vm.launchAtLogin = true
        #expect(vm.loginItemStatus == .requiresApproval)
        #expect(vm.launchAtLogin == false)
    }

    @Test func refresh_login_item_status_picks_up_external_approval() {
        let backend = StubLoginBackend(status: .requiresApproval)
        let svc = LoginItemService(backend: backend)
        let vm = GeneralSettingsViewModel(
            settings: AppSettings(defaults: defaults()),
            applier: NoopApplier(),
            loginItemService: svc
        )
        #expect(vm.launchAtLogin == false)
        backend.status = .enabled
        vm.refreshLoginItemStatus()
        #expect(vm.loginItemStatus == .enabled)
        #expect(vm.launchAtLogin == true)
    }
}

private struct NoopApplier: GeneralSettingsApplier {
    func apply(_ snapshot: GeneralSettingsSnapshot) {}
}

@MainActor
private final class RecordingApplier: GeneralSettingsApplier {
    var applied: GeneralSettingsSnapshot?
    func apply(_ snapshot: GeneralSettingsSnapshot) { applied = snapshot }
}
