import Foundation

enum MeetingTime {

    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "00:00:00" }
        let total = max(0, Int(seconds))
        return String(format: "%02d:%02d:%02d", total / 3_600, (total % 3_600) / 60, total % 60)
    }

    /// Whole minutes, at least 1.
    static func minutes(_ duration: TimeInterval) -> Int {
        max(1, Int((duration / 60).rounded()))
    }
}

struct MeetingDocument: Equatable, Sendable {
    var startedAt: Date
    var duration: TimeInterval
    var utterances: [MeetingUtterance]
    var notes: MeetingNotes?
    var notesFailure: String?
    var warnings: [String]
}

enum MeetingMarkdown {

    static let untitled = "Meeting"
    static let noneRecorded = "None recorded."

    static func render(_ document: MeetingDocument, timeZone: TimeZone = .current) -> String {
        let names = document.notes?.speakerNames ?? []
        let title = document.notes.map(\.title).flatMap { $0.isEmpty ? nil : $0 } ?? untitled
        var out: [String] = ["# \(title)", header(document, names: names, timeZone: timeZone), ""]

        if let failure = document.notesFailure {
            out += ["> Notes not generated: \(failure) Use Regenerate Notes in the menu.", ""]
        }
        for warning in document.warnings {
            out += ["> \(warning)", ""]
        }

        if let notes = document.notes {
            out += ["## Summary", notes.summary.isEmpty ? noneRecorded : notes.summary, ""]
            out += section("Key points", notes.keyPoints)
            out += section("Decisions", notes.decisions)
            out += section("Action items", notes.actionItems.map { item in
                var line = "[ ] **\(displayName(item.owner, names: names))** — \(item.task)"
                if let due = item.due { line += " — due \(due)" }
                return line
            })
            out += section("Open questions", notes.openQuestions)
        }

        out += ["---", "", "## Transcript", ""]
        for utterance in document.utterances {
            out += ["**\(displayName(utterance.speaker, names: names))** [\(MeetingTime.clock(utterance.start))] \(utterance.text)", ""]
        }
        return out.joined(separator: "\n")
    }

    static func displayName(_ label: String, names: [MeetingNotes.SpeakerName]) -> String {
        guard let name = names.first(where: { $0.label == label })?.name else { return label }
        return "\(label) (\(name))"
    }

    static func speakers(in utterances: [MeetingUtterance]) -> [String] {
        var seen: [String] = []
        for utterance in utterances where !seen.contains(utterance.speaker) {
            seen.append(utterance.speaker)
        }
        return seen
    }

    private static func header(_ document: MeetingDocument, names: [MeetingNotes.SpeakerName], timeZone: TimeZone) -> String {
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = timeZone
        day.dateFormat = "yyyy-MM-dd"
        let time = DateFormatter()
        time.locale = Locale(identifier: "en_US_POSIX")
        time.timeZone = timeZone
        time.dateFormat = "HH:mm"
        let end = document.startedAt.addingTimeInterval(document.duration)
        let speakers = speakers(in: document.utterances).map { displayName($0, names: names) }.joined(separator: ", ")
        var line = "\(day.string(from: document.startedAt)) · \(time.string(from: document.startedAt))–\(time.string(from: end)) (\(MeetingTime.minutes(document.duration)) min)"
        if !speakers.isEmpty { line += " · \(speakers)" }
        return line
    }

    private static func section(_ heading: String, _ items: [String]) -> [String] {
        ["## \(heading)"] + (items.isEmpty ? [noneRecorded] : items.map { "- \($0)" }) + [""]
    }
}
