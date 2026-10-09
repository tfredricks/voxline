import Foundation
import Testing
@testable import voxline

@Suite struct MeetingNotesPromptTests {

    private let utc = TimeZone(identifier: "UTC")!

    private func request(vocabulary: [String] = []) -> MeetingNotesRequest {
        MeetingNotesRequest(
            model: "m",
            utterances: [
                MeetingUtterance(speaker: "Me", start: 12, end: 14, text: "Thanks for joining."),
                MeetingUtterance(speaker: "Speaker 1", start: 3_725, end: 3_727, text: "Bye."),
            ],
            startedAt: Date(timeIntervalSince1970: 1_791_554_520),
            duration: 2_760,
            vocabulary: vocabulary
        )
    }

    @Test func user_message_lists_date_duration_and_timestamped_lines() {
        let text = MeetingNotesPrompt.user(request(), timeZone: utc)
        #expect(text == """
        Meeting date: 2026-10-09 14:02
        Duration: 46 min

        Transcript:
        [00:00:12] Me: Thanks for joining.
        [01:02:05] Speaker 1: Bye.
        """)
    }

    @Test func vocabulary_line_only_when_present() {
        #expect(!MeetingNotesPrompt.user(request(), timeZone: utc).contains("Vocabulary:"))
        #expect(MeetingNotesPrompt.user(request(vocabulary: ["LangGraph", "Argmax"]), timeZone: utc)
            .contains("Vocabulary: LangGraph, Argmax\n"))
    }

    @Test func system_prompt_forbids_guessing_names_and_dates() {
        #expect(MeetingNotesPrompt.system.contains("Never guess a name."))
        #expect(MeetingNotesPrompt.system.contains("Never invent dates."))
    }

    @Test func clock_formats_hours_minutes_seconds() {
        #expect(MeetingTime.clock(0) == "00:00:00")
        #expect(MeetingTime.clock(3_725.9) == "01:02:05")
    }
}
