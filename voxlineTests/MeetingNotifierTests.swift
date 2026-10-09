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

    @Test func notes_ready_names_the_file() {
        let text = UserNotificationMeetingNotifier.text(for: .notesReady(URL(fileURLWithPath: "/tmp/2026-10-09 Standup.md")))
        #expect(text.title == "Meeting notes ready")
        #expect(text.body == "2026-10-09 Standup")
    }
}
