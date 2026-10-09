import Foundation

struct LiveLine: Equatable, Identifiable, Sendable {
    let id: Int
    var track: MeetingRecorder.Track
    var text: String
}

struct LiveTranscript: Equatable, Sendable {
    var lines: [LiveLine] = []
    var volatile: [MeetingRecorder.Track: String] = [:]
}

/// Turns each track's running `TranscriptPartial` into labeled lines for the
/// live panel. A finished segment joins the newest line when that line is
/// from the same track; a `stable` that does not extend the previous one
/// (a restarted session) is taken whole as a new segment.
struct LiveTranscriptAssembler {

    static let defaultMaxLines = 50

    let maxLines: Int
    private(set) var transcript = LiveTranscript()
    private var stable: [MeetingRecorder.Track: String] = [:]
    private var nextID = 0

    init(maxLines: Int = LiveTranscriptAssembler.defaultMaxLines) {
        self.maxLines = maxLines
    }

    mutating func apply(_ partial: TranscriptPartial, track: MeetingRecorder.Track) -> LiveTranscript {
        let previous = stable[track] ?? ""
        let segment = partial.stable.hasPrefix(previous)
            ? String(partial.stable.dropFirst(previous.count))
            : partial.stable
        stable[track] = partial.stable
        let text = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { append(text, track: track) }
        let tail = partial.volatile.trimmingCharacters(in: .whitespacesAndNewlines)
        transcript.volatile[track] = tail.isEmpty ? nil : tail
        return transcript
    }

    private mutating func append(_ text: String, track: MeetingRecorder.Track) {
        if let last = transcript.lines.indices.last, transcript.lines[last].track == track {
            transcript.lines[last].text = TranscriptPartial.join(transcript.lines[last].text, text)
            return
        }
        transcript.lines.append(LiveLine(id: nextID, track: track, text: text))
        nextID += 1
        if transcript.lines.count > maxLines {
            transcript.lines.removeFirst(transcript.lines.count - maxLines)
        }
    }
}
