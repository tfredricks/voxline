import Foundation
import WhisperKit

/// One track's transcription: segments for merging, and WhisperKit's raw
/// results for SpeakerKit's word-level alignment.
struct TrackTranscript: @unchecked Sendable {
    var segments: [TimedSegment]
    var results: [TranscriptionResult]

    init(segments: [TimedSegment], results: [TranscriptionResult] = []) {
        self.segments = segments
        self.results = results
    }
}

protocol MeetingTranscribing: Sendable {
    func transcribe(_ samples: [Float]) async throws -> TrackTranscript
    /// Frees the loaded model; the next transcribe loads it again.
    func release() async
}

protocol MeetingDiarizing: Sendable {
    func diarize(_ samples: [Float], transcript: TrackTranscript) async throws -> [SpeakerSegmentText]
    func release() async
}

enum MeetingSpeechConversion {

    struct RawSegment {
        var start: Float
        var end: Float
        var text: String
    }

    struct RawSpeakerSegment {
        var speakerIDs: [Int]
        var start: Float
        var end: Float
        var text: String
    }

    static func timedSegments(_ raw: [RawSegment]) -> [TimedSegment] {
        raw.compactMap { segment in
            let text = WhisperSegmentText.clean(segment.text).trimmed
            return text.isEmpty ? nil : TimedSegment(start: Double(segment.start), end: Double(segment.end), text: text)
        }
    }

    static func speakerSegments(_ raw: [RawSpeakerSegment]) -> [SpeakerSegmentText] {
        raw.compactMap { segment in
            let text = WhisperSegmentText.clean(segment.text).trimmed
            guard !text.isEmpty else { return nil }
            return SpeakerSegmentText(
                speakerID: segment.speakerIDs.first,
                start: Double(segment.start),
                end: Double(segment.end),
                text: text
            )
        }
    }
}
