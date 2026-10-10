import Foundation
import Testing
@testable import voxline

@Suite struct MeetingNotifierTests {

    @Test func failed_processing_points_to_retry_processing() {
        let text = UserNotificationMeetingNotifier.text(for: .failed("Transcription failed.", retryable: true))
        #expect(text.title == "Couldn't finish the meeting notes")
        #expect(text.body == "Transcription failed. Choose Retry Processing in the Voxline menu.")
    }

    @Test func failed_regenerate_points_to_regenerate_notes() {
        let text = UserNotificationMeetingNotifier.text(for: .failed("Notes failed.", retryable: false))
        #expect(text.title == "Couldn't finish the meeting notes")
        #expect(text.body == "Notes failed. Choose Regenerate Notes in the Voxline menu to try again.")
    }

    @Test func recording_stopped_gives_the_reason_and_what_happens_next() {
        let text = UserNotificationMeetingNotifier.text(for: .recordingStopped("The microphone stopped and couldn't be restarted."))
        #expect(text.title == "Meeting recording stopped")
        #expect(text.body == "The microphone stopped and couldn't be restarted. Notes will be written for what was recorded.")
    }

    @Test func recording_stopped_adds_a_missing_period() {
        let text = UserNotificationMeetingNotifier.text(for: .recordingStopped("Couldn't write meeting audio: disk full"))
        #expect(text.body == "Couldn't write meeting audio: disk full. Notes will be written for what was recorded.")
    }

    @Test func system_audio_lost_says_the_mic_continues() {
        let text = UserNotificationMeetingNotifier.text(for: .systemAudioLost)
        #expect(text.title == "System audio capture stopped")
        #expect(text.body == "Recording continues with your microphone only.")
    }

    @Test func busy_says_recording_did_not_start() {
        let text = UserNotificationMeetingNotifier.text(for: .busy)
        #expect(text.title == "Meeting recording didn't start")
        #expect(text.body == "Voxline is still processing the last meeting. Try again when its notes are ready.")
    }

    @Test func notes_ready_names_the_file() {
        let text = UserNotificationMeetingNotifier.text(for: .notesReady(URL(fileURLWithPath: "/tmp/2026-10-09 Standup.md")))
        #expect(text.title == "Meeting notes ready")
        #expect(text.body == "2026-10-09 Standup")
    }
}
