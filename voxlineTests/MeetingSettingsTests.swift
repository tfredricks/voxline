import Foundation
import Testing
@testable import voxline

@Suite struct MeetingSettingsTests {

    private func makeSettings() -> AppSettings {
        AppSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
    }

    @Test func notes_folder_defaults_to_documents_voxline_meetings() {
        let settings = makeSettings()
        #expect(settings.meetingNotesFolder.lastPathComponent == "voxline Meetings")
        #expect(settings.meetingNotesFolder.deletingLastPathComponent().lastPathComponent == "Documents")
    }

    @Test func notes_folder_round_trips() {
        var settings = makeSettings()
        settings.meetingNotesFolder = URL(fileURLWithPath: "/tmp/notes", isDirectory: true)
        #expect(settings.meetingNotesFolder.path == "/tmp/notes")
    }

    @Test func shortcut_round_trips_and_clears() {
        var settings = makeSettings()
        #expect(settings.meetingShortcut == nil)
        let combo = KeyCombo(keyCode: 46, modifiers: [.control, .option])
        settings.meetingShortcut = combo
        #expect(settings.meetingShortcut == combo)
        settings.meetingShortcut = nil
        #expect(settings.meetingShortcut == nil)
    }

    @Test func notes_model_falls_back_to_command_then_cleanup_model() {
        var settings = makeSettings()
        settings.llmModel = "claude-haiku-4-5"
        #expect(settings.resolvedMeetingNotesModel == "claude-haiku-4-5")
        settings.commandModel = "claude-sonnet-5-5"
        #expect(settings.resolvedMeetingNotesModel == "claude-sonnet-5-5")
        settings.meetingNotesModel = "  claude-opus-5-5 "
        #expect(settings.resolvedMeetingNotesModel == "claude-opus-5-5")
        settings.meetingNotesModel = "   "
        #expect(settings.meetingNotesModel == nil)
    }

    @Test func provider_change_clears_notes_model() {
        var settings = makeSettings()
        settings.llmProvider = .anthropic
        settings.meetingNotesModel = "claude-sonnet-5-5"
        settings.llmProvider = .openai
        #expect(settings.meetingNotesModel == nil)
    }

    @Test func retention_and_timer_defaults() {
        var settings = makeSettings()
        #expect(settings.meetingAudioRetention == .days14)
        #expect(settings.showMeetingTimer)
        settings.meetingAudioRetention = .forever
        settings.showMeetingTimer = false
        #expect(settings.meetingAudioRetention == .forever)
        #expect(!settings.showMeetingTimer)
    }

    @Test func cap_override_ignores_unset_and_non_positive() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let settings = AppSettings(defaults: defaults)
        #expect(settings.meetingCapSeconds == nil)
        defaults.set(0, forKey: AppSettings.Key.meetingCapSeconds)
        #expect(settings.meetingCapSeconds == nil)
        defaults.set(120, forKey: AppSettings.Key.meetingCapSeconds)
        #expect(settings.meetingCapSeconds == 120)
    }

    @Test func live_transcript_defaults_on_and_round_trips() {
        var settings = makeSettings()
        #expect(settings.meetingLiveTranscript)
        #expect(settings.liveTranscriptEnabled)
        settings.meetingLiveTranscript = false
        #expect(!settings.meetingLiveTranscript)
        #expect(!settings.liveTranscriptEnabled)
    }

    @Test func live_transcript_needs_the_timer() {
        var settings = makeSettings()
        settings.showMeetingTimer = false
        #expect(settings.meetingLiveTranscript)
        #expect(!settings.liveTranscriptEnabled)
    }

    @Test func live_panel_expanded_defaults_off_and_round_trips() {
        var settings = makeSettings()
        #expect(!settings.meetingLivePanelExpanded)
        settings.meetingLivePanelExpanded = true
        #expect(settings.meetingLivePanelExpanded)
    }
}
