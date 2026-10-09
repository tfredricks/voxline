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
    /// Loads (downloading if needed) the model. Idempotent.
    func prepare() async throws
    func transcribe(_ samples: [Float]) async throws -> TrackTranscript
    /// Frees the loaded model; the next transcribe loads it again.
    func release() async
}

/// Returns `[]` only when the transcript has no segments (nothing to diarize).
/// Throws `MeetingDiarizationError` when diarization was impossible or its
/// output could not be matched to the transcript.
protocol MeetingDiarizing: Sendable {
    /// Loads (downloading if needed) the model. Idempotent.
    func prepare() async throws
    func diarize(_ samples: [Float], transcript: TrackTranscript) async throws -> [SpeakerSegmentText]
    func release() async
}

enum MeetingDiarizationError: LocalizedError, Equatable {
    case noWordTimings
    case speakersNotMatched

    var errorDescription: String? {
        switch self {
        case .noWordTimings: "the transcript had no word timings to align speakers to."
        case .speakersNotMatched: "speakers couldn't be matched to the transcript."
        }
    }
}

enum MeetingSpeechConversion {

    static func requireWordTimings(wordCount: Int) throws {
        if wordCount == 0 { throw MeetingDiarizationError.noWordTimings }
    }

    static func requireMatched(transcriptSegments: Int, speakerSegments: Int) throws {
        if transcriptSegments > 0, speakerSegments == 0 { throw MeetingDiarizationError.speakersNotMatched }
    }

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
