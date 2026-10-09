import Foundation
import Testing
@testable import voxline

@Suite struct MeetingSpeechTests {

    @Test func timed_segments_clean_text_and_drop_blanks() {
        let segments = MeetingSpeechConversion.timedSegments([
            .init(start: 0, end: 1.5, text: "<|startoftranscript|><|0.00|> Hello there.<|1.50|>"),
            .init(start: 2, end: 3, text: "<|2.00|><|3.00|>"),
        ])
        #expect(segments == [TimedSegment(start: 0, end: 1.5, text: "Hello there.")])
    }

    @Test func speaker_ids_single_multiple_and_none() {
        let segments = MeetingSpeechConversion.speakerSegments([
            .init(speakerIDs: [3], start: 0, end: 1, text: " One"),
            .init(speakerIDs: [5, 3], start: 1, end: 2, text: " Two"),
            .init(speakerIDs: [], start: 2, end: 3, text: " Three"),
            .init(speakerIDs: [1], start: 3, end: 4, text: "  "),
        ])
        #expect(segments.map(\.speakerID) == [3, 5, nil])
        #expect(segments.map(\.text) == ["One", "Two", "Three"])
    }

    @Test func track_transcript_defaults_to_no_results() {
        let transcript = TrackTranscript(segments: [TimedSegment(start: 0, end: 1, text: "a")])
        #expect(transcript.results.isEmpty)
    }
}
