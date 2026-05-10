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

        let vm = GeneralSettingsViewModel(settings: settings, applier: NoopApplier())
        #expect(vm.chord == chord)
        #expect(vm.audioInputDeviceUID == "MyMic")
        #expect(vm.whisperModel == .smallEn)
        #expect(vm.playHotkeySounds == false)
    }

    @Test func save_persists_and_calls_applier() {
        let d = defaults()
        let settings = AppSettings(defaults: d)
        let applier = RecordingApplier()
        let vm = GeneralSettingsViewModel(settings: settings, applier: applier)

        let chord = HotkeyChord(modifierA: .rightCommand, modifierB: .rightShift)
        vm.chord = chord
        vm.audioInputDeviceUID = "NewMic"
        vm.whisperModel = .smallEn
        vm.playHotkeySounds = false
        vm.save()

        let reread = AppSettings(defaults: d)
        #expect(reread.hotkeyChord == chord)
        #expect(reread.audioInputDeviceUID == "NewMic")
        #expect(reread.whisperModel == .smallEn)
        #expect(reread.playHotkeySounds == false)

        #expect(applier.applied?.chord == chord)
        #expect(applier.applied?.audioInputDeviceUID == "NewMic")
        #expect(applier.applied?.whisperModel == .smallEn)
        #expect(applier.applied?.playHotkeySounds == false)
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
}

private struct NoopApplier: GeneralSettingsApplier {
    func apply(_ snapshot: GeneralSettingsSnapshot) {}
}

@MainActor
private final class RecordingApplier: GeneralSettingsApplier {
    var applied: GeneralSettingsSnapshot?
    func apply(_ snapshot: GeneralSettingsSnapshot) { applied = snapshot }
}
