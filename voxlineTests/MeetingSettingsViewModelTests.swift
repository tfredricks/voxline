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

    @Test func reload_shows_a_notes_model_cleared_by_a_provider_change() {
        let changes = LockedBox(0)
        var settings = AppSettings(defaults: defaults)
        settings.llmProvider = .anthropic
        let vm = model(changes: changes)
        vm.notesModel = "claude-sonnet-5-5"
        settings.llmProvider = .openai

        vm.reload()

        #expect(vm.notesModel == "")
        #expect(AppSettings(defaults: defaults).meetingNotesModel == nil)
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

    @Test func app_shortcut_warning_is_kept_and_shown() {
        let vm = model()
        let commandM = KeyCombo(keyCode: 46, modifiers: [.command])
        guard case .warning(let message) = vm.updateShortcut(commandM) else {
            Issue.record("expected a warning")
            return
        }
        #expect(vm.shortcut == commandM)
        #expect(vm.shortcutWarning == message)
    }

    @Test func clean_shortcut_has_no_warning() {
        let vm = model()
        #expect(vm.shortcutWarning == nil)
        vm.updateShortcut(combo)
        #expect(vm.shortcutWarning == nil)
    }

    @Test func shortcut_warning_follows_the_current_chords() {
        let chords = LockedBox(ChordSet.default)
        let vm = MeetingSettingsViewModel(
            settings: AppSettings(defaults: defaults),
            presets: { [] },
            chords: { chords.read() },
            onChange: {},
            translate: { _, _ in nil }
        )
        #expect(vm.updateShortcut(combo) == .ok)

        chords.write(ChordSet(dictation: HotkeyChord(modifierA: .leftControl, modifierB: .leftOption), command: nil))
        #expect(vm.shortcutWarning == "⌃⌥ is your dictation hotkey")

        chords.write(.default)
        #expect(vm.shortcutWarning == nil)
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

    @Test func live_transcript_toggle_writes_through_and_reports() {
        let changes = LockedBox(0)
        let vm = model(changes: changes)
        #expect(vm.liveTranscript)
        vm.liveTranscript = false
        #expect(!AppSettings(defaults: defaults).meetingLiveTranscript)
        #expect(changes.read() == 1)
    }
}
