import Foundation
import Testing
@testable import voxline

@MainActor
@Suite struct MeetingSettingsViewModelTests {

    private let defaults = UserDefaults(suiteName: UUID().uuidString)!
    private let combo = KeyCombo(keyCode: 46, modifiers: [.control, .option])

    private func model(presets: [PresetShortcut] = [], changes: LockedBox<Int> = LockedBox(0)) -> MeetingSettingsViewModel {
        MeetingSettingsViewModel(
            settings: AppSettings(defaults: defaults),
            presets: { presets },
            chords: { ChordSet.default },
            onChange: { changes.mutate { $0 += 1 } },
            translate: { _, _ in nil }
        )
    }

    @Test func accepted_shortcut_is_saved_and_reported() {
        let changes = LockedBox(0)
        let vm = model(changes: changes)
        #expect(vm.updateShortcut(combo) == .ok)
        #expect(vm.shortcut == combo)
        #expect(AppSettings(defaults: defaults).meetingShortcut == combo)
        #expect(changes.read() == 1)
    }

    @Test func shortcut_used_by_a_preset_is_rejected() {
        var preset = PresetShortcut.defaults[0]
        preset.combo = combo
        let vm = model(presets: [preset])
        #expect(vm.updateShortcut(combo) == .rejected(MeetingSettingsViewModel.presetTaken))
        #expect(vm.shortcut == nil)
    }

    @Test func shortcut_without_command_option_or_control_is_rejected() {
        let vm = model()
        guard case .rejected = vm.updateShortcut(KeyCombo(keyCode: 46, modifiers: [.shift])) else {
            Issue.record("expected rejection")
            return
        }
    }

    @Test func clear_removes_the_shortcut() {
        let vm = model()
        vm.updateShortcut(combo)
        vm.clearShortcut()
        #expect(vm.shortcut == nil)
        #expect(AppSettings(defaults: defaults).meetingShortcut == nil)
    }

    @Test func fields_write_through() {
        let vm = model()
        vm.notesModel = "claude-sonnet-5-5"
        vm.retention = .days30
        vm.showTimer = false
        vm.setNotesFolder(URL(fileURLWithPath: "/tmp/m", isDirectory: true))
        let settings = AppSettings(defaults: defaults)
        #expect(settings.meetingNotesModel == "claude-sonnet-5-5")
        #expect(settings.meetingAudioRetention == .days30)
        #expect(!settings.showMeetingTimer)
        #expect(settings.meetingNotesFolder.path == "/tmp/m")
    }
}
