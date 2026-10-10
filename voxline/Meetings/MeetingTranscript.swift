import Foundation

/// Transcribed text with its time range in the track, in seconds.
struct TimedSegment: Codable, Equatable, Sendable {
    var start: Double
    var end: Double
    var text: String
}

/// A diarized segment. `speakerID` is the diarizer's cluster id; nil when
/// the diarizer matched no single speaker or did not run.
struct SpeakerSegmentText: Equatable, Sendable {
    var speakerID: Int?
    var start: Double
    var end: Double
    var text: String
}

struct MeetingUtterance: Codable, Equatable, Sendable {
    var speaker: String
    var start: Double
    var end: Double
    var text: String
}

enum TranscriptMerger {

    static let meLabel = "Me"
    static let joinGap: Double = 2
    static let echoTolerance: Double = 1.5
    static let echoWordOverlap: Double = 0.6

    static func merge(mic: [TimedSegment], others: [SpeakerSegmentText], unattributedLabel: String) -> [MeetingUtterance] {
        let labeledOthers = label(others.filter { !$0.text.isBlank }.sorted { $0.start < $1.start }, unattributedLabel: unattributedLabel)
        let keptMic = mic
            .filter { !$0.text.isBlank && !isEcho($0, of: others) }
            .map { MeetingUtterance(speaker: meLabel, start: $0.start, end: $0.end, text: $0.text.trimmed) }
        let ordered = (keptMic + labeledOthers).sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.speaker == meLabel && $1.speaker != meLabel
        }
        return join(ordered)
    }

    /// True when at least `echoWordOverlap` of the mic segment's words
    /// appear, in order, in the other segments within `echoTolerance` of it,
    /// taken together: diarization splits one remote passage into many short
    /// segments. Requiring the order keeps a reply that shares common words
    /// with the speech around it.
    static func isEcho(_ mic: TimedSegment, of others: [SpeakerSegmentText]) -> Bool {
        let micWords = normalizedWords(mic.text)
        guard !micWords.isEmpty else { return false }
        let nearbyWords = others
            .filter { mic.start <= $0.end + echoTolerance && mic.end >= $0.start - echoTolerance }
            .sorted { $0.start < $1.start }
            .flatMap { normalizedWords($0.text) }
        return Double(orderedMatchCount(micWords, nearbyWords)) / Double(micWords.count) >= echoWordOverlap
    }

    /// The length of the longest common subsequence of `a` and `b`.
    static func orderedMatchCount(_ a: [String], _ b: [String]) -> Int {
        var previous = [Int](repeating: 0, count: b.count + 1)
        var current = previous
        for word in a {
            for (j, other) in b.enumerated() {
                current[j + 1] = word == other ? previous[j] + 1 : max(previous[j + 1], current[j])
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    static func normalizedWords(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'")).inverted)
            .filter { !$0.isEmpty }
    }

    private static func label(_ segments: [SpeakerSegmentText], unattributedLabel: String) -> [MeetingUtterance] {
        var names: [Int: String] = [:]
        var previous: String?
        return segments.map { segment in
            let speaker: String
            if let id = segment.speakerID {
                if names[id] == nil { names[id] = "Speaker \(names.count + 1)" }
                speaker = names[id]!
                previous = speaker
            } else {
                speaker = previous ?? unattributedLabel
            }
            return MeetingUtterance(speaker: speaker, start: segment.start, end: segment.end, text: segment.text.trimmed)
        }
    }

    private static func join(_ utterances: [MeetingUtterance]) -> [MeetingUtterance] {
        var out: [MeetingUtterance] = []
        for utterance in utterances {
            if var last = out.last, last.speaker == utterance.speaker, utterance.start - last.end < joinGap {
                last.text = TranscriptPartial.join(last.text, utterance.text)
                last.end = max(last.end, utterance.end)
                out[out.count - 1] = last
            } else {
                out.append(utterance)
            }
        }
        return out
    }
}
