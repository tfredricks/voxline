import Foundation
import Testing
@testable import voxline

@Suite struct MeetingMarkdownTests {

    private let utc = TimeZone(identifier: "UTC")!
    private let start = Date(timeIntervalSince1970: 1_791_554_520)

    private let utterances = [
        MeetingUtterance(speaker: "Me", start: 12, end: 14, text: "Thanks for joining."),
        MeetingUtterance(speaker: "Speaker 1", start: 31, end: 35, text: "Happy to be here."),
        MeetingUtterance(speaker: "Speaker 2", start: 40, end: 42, text: "Hi."),
    ]

    private let notes = MeetingNotes(
        title: "Q4 pricing review",
        summary: "We reviewed pricing.",
        keyPoints: ["Discount requested"],
        decisions: [],
        actionItems: [
            .init(owner: "Me", task: "send revised quote", due: "Friday"),
            .init(owner: "Speaker 2", task: "confirm seat count", due: nil),
        ],
        openQuestions: ["SSO in phase one?"],
        speakerNames: [.init(label: "Speaker 2", name: "Priya")]
    )

    @Test func renders_full_document() {
        let doc = MeetingDocument(startedAt: start, duration: 2_760, utterances: utterances, notes: notes, notesFailure: nil, warnings: [])
        #expect(MeetingMarkdown.render(doc, timeZone: utc) == """
        # Q4 pricing review
        2026-10-09 · 14:02–14:48 (46 min) · Me, Speaker 1, Speaker 2 (Priya)

        ## Summary
        We reviewed pricing.

        ## Key points
        - Discount requested

        ## Decisions
        None recorded.

        ## Action items
        - [ ] **Me** — send revised quote — due Friday
        - [ ] **Speaker 2 (Priya)** — confirm seat count

        ## Open questions
        - SSO in phase one?

        ---

        ## Transcript

        **Me** [00:00:12] Thanks for joining.

        **Speaker 1** [00:00:31] Happy to be here.

        **Speaker 2 (Priya)** [00:00:40] Hi.

        """)
    }

    @Test func notes_failure_renders_note_and_transcript_only() {
        let doc = MeetingDocument(
            startedAt: start, duration: 60, utterances: [utterances[0]], notes: nil,
            notesFailure: "No API key configured.", warnings: ["Speakers could not be separated."]
        )
        #expect(MeetingMarkdown.render(doc, timeZone: utc) == """
        # Meeting
        2026-10-09 · 14:02–14:03 (1 min) · Me

        > Notes not generated: No API key configured. Use Regenerate Notes in the menu.

        > Speakers could not be separated.

        ---

        ## Transcript

        **Me** [00:00:12] Thanks for joining.

        """)
    }

    @Test func speakers_in_first_appearance_order() {
        let list = MeetingMarkdown.speakers(in: [utterances[1], utterances[0], utterances[1]])
        #expect(list == ["Speaker 1", "Me"])
    }

    @Test func clock_formats_seconds_and_survives_non_finite_input() {
        #expect(MeetingTime.clock(3_725.9) == "01:02:05")
        #expect(MeetingTime.clock(-4) == "00:00:00")
        #expect(MeetingTime.clock(.nan) == "00:00:00")
        #expect(MeetingTime.clock(.infinity) == "00:00:00")
        #expect(MeetingTime.clock(-.infinity) == "00:00:00")
    }
}
