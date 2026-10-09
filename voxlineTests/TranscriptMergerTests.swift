import Foundation
import Testing
@testable import voxline

@Suite struct TranscriptMergerTests {

    private func mic(_ start: Double, _ end: Double, _ text: String) -> TimedSegment {
        TimedSegment(start: start, end: end, text: text)
    }

    private func other(_ id: Int?, _ start: Double, _ end: Double, _ text: String) -> SpeakerSegmentText {
        SpeakerSegmentText(speakerID: id, start: start, end: end, text: text)
    }

    @Test func interleaves_by_start_time_and_numbers_speakers_by_first_appearance() {
        let result = TranscriptMerger.merge(
            mic: [mic(5, 7, "I can do eight percent.")],
            others: [other(7, 0, 3, "Thanks for joining."), other(2, 10, 12, "Who sends the quote?")],
            unattributedLabel: "Them"
        )
        #expect(result.map(\.speaker) == ["Speaker 1", "Me", "Speaker 2"])
        #expect(result.map(\.text) == ["Thanks for joining.", "I can do eight percent.", "Who sends the quote?"])
    }

    @Test func joins_same_speaker_runs_under_two_seconds() {
        let result = TranscriptMerger.merge(
            mic: [mic(0, 2, "First part."), mic(3.9, 5, "Second part."), mic(8, 9, "Later.")],
            others: [],
            unattributedLabel: "Them"
        )
        #expect(result.count == 2)
        #expect(result[0].text == "First part. Second part.")
        #expect(result[0].end == 5)
        #expect(result[1].text == "Later.")
    }

    @Test func gap_of_exactly_two_seconds_does_not_join() {
        let result = TranscriptMerger.merge(
            mic: [mic(0, 1, "A."), mic(3, 4, "B.")], others: [], unattributedLabel: "Them"
        )
        #expect(result.count == 2)
    }

    @Test func unattributed_segment_takes_previous_speaker_label() {
        let result = TranscriptMerger.merge(
            mic: [],
            others: [other(4, 0, 2, "Hello there."), other(nil, 2.5, 3, "and more"), other(9, 10, 11, "Hi.")],
            unattributedLabel: "Them"
        )
        #expect(result.map(\.speaker) == ["Speaker 1", "Speaker 2"])
        #expect(result[0].text == "Hello there. and more")
    }

    @Test func all_unattributed_uses_fallback_label() {
        let result = TranscriptMerger.merge(
            mic: [], others: [other(nil, 0, 1, "One."), other(nil, 5, 6, "Two.")], unattributedLabel: "Them"
        )
        #expect(result.map(\.speaker) == ["Them", "Them"])
    }

    @Test func echoed_mic_segment_is_dropped() {
        let result = TranscriptMerger.merge(
            mic: [mic(10.5, 13, "they asked for a ten percent discount")],
            others: [other(1, 10, 12.5, "They asked for a ten percent discount if they commit.")],
            unattributedLabel: "Them"
        )
        #expect(result.map(\.speaker) == ["Speaker 1"])
    }

    @Test func mic_segment_outside_time_tolerance_is_kept() {
        let result = TranscriptMerger.merge(
            mic: [mic(14.1, 16, "they asked for a ten percent discount")],
            others: [other(1, 10, 12.5, "They asked for a ten percent discount.")],
            unattributedLabel: "Them"
        )
        #expect(result.map(\.speaker) == ["Speaker 1", "Me"])
    }

    @Test func echo_threshold_is_sixty_percent_of_mic_words() {
        let others = [other(1, 0, 5, "alpha beta gamma delta epsilon")]
        #expect(TranscriptMerger.isEcho(mic(0, 5, "alpha beta gamma zulu yankee"), of: others))
        #expect(!TranscriptMerger.isEcho(mic(0, 5, "alpha beta xray zulu yankee"), of: others))
    }

    @Test func normalized_words_ignore_case_and_punctuation() {
        #expect(TranscriptMerger.normalizedWords("Hello, World! It's 10%.") == ["hello", "world", "it's", "10"])
    }

    @Test func blank_segments_are_dropped() {
        let result = TranscriptMerger.merge(mic: [mic(0, 1, "  ")], others: [other(1, 2, 3, "")], unattributedLabel: "Them")
        #expect(result.isEmpty)
    }
}
