import Foundation
import Testing
@testable import voxline

@Suite struct RecentMeetingsTests {

    private func meta(_ seconds: TimeInterval, state: MeetingState = .done, title: String? = "Standup", notes: String? = "/notes/a.md") -> MeetingMeta {
        MeetingMeta(
            id: UUID(), state: state, startedAt: Date(timeIntervalSince1970: seconds), durationSeconds: 600,
            systemTapStarted: true, title: title, notesPath: notes, failureReason: nil
        )
    }

    @Test func newest_first_limited_to_five() {
        let metas = (0..<7).map { meta(TimeInterval($0) * 100) }
        let rows = RecentMeetings.rows(metas: metas, phase: .idle, fileExists: { _ in true })
        #expect(rows.count == 5)
        #expect(rows.map(\.startedAt) == metas.sorted { $0.startedAt > $1.startedAt }.prefix(5).map(\.startedAt))
    }

    @Test func missing_title_uses_untitled() {
        let rows = RecentMeetings.rows(metas: [meta(0, title: nil)], phase: .idle, fileExists: { _ in true })
        #expect(rows.first?.title == MeetingMarkdown.untitled)
    }

    @Test func notes_url_only_when_the_file_exists() {
        let present = meta(0, notes: "/notes/here.md")
        let gone = meta(1, notes: "/notes/gone.md")
        let none = meta(2, notes: nil)
        let rows = RecentMeetings.rows(
            metas: [present, gone, none], phase: .idle,
            fileExists: { $0.path == "/notes/here.md" }
        )
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        #expect(byID[present.id]?.notesURL == URL(fileURLWithPath: "/notes/here.md"))
        #expect(byID[gone.id]?.notesURL == nil)
        #expect(byID[none.id]?.notesURL == nil)
    }

    @Test func in_progress_meetings_show_a_stage() {
        let processing = meta(2, state: .processing, notes: nil)
        let recording = meta(1, state: .recording, notes: nil)
        let waiting = meta(0, state: .recorded, notes: nil)
        let rows = RecentMeetings.rows(
            metas: [processing, recording, waiting], phase: .processing(.writingNotes),
            fileExists: { _ in false }
        )
        #expect(rows[0].stageLabel == "Writing notes…")
        #expect(rows[1].stageLabel == "Recording…")
        #expect(rows[2].stageLabel == "Waiting to process…")
    }

    @Test func processing_without_a_stage_has_a_generic_label() {
        let rows = RecentMeetings.rows(metas: [meta(0, state: .processing)], phase: .processing(nil), fileExists: { _ in false })
        #expect(rows.first?.stageLabel == "Processing…")
    }

    @Test func retry_on_every_failed_meeting() {
        let failed = meta(2, state: .failed, notes: nil)
        let done = meta(1)
        let otherFailed = meta(0, state: .failed, notes: nil)
        let rows = RecentMeetings.rows(metas: [failed, done, otherFailed], phase: .idle, fileExists: { _ in false })
        #expect(rows.map(\.showsRetry) == [true, false, true])
        #expect(rows[0].stageLabel == "Failed")
        #expect(rows[2].stageLabel == "Failed")
    }
}
