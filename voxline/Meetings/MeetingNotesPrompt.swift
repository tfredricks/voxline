import Foundation

enum MeetingNotesPrompt {

    static let system = """
    You write meeting notes from a speaker-labeled transcript. Reply with one \
    JSON object matching the schema: title, summary, keyPoints, decisions, \
    actionItems, openQuestions, speakerNames.

    Rules:
    - title: a short, specific title for the meeting, at most 8 words.
    - summary: 3 to 5 sentences covering the purpose, the main outcomes, and \
    the next steps.
    - keyPoints, decisions, openQuestions: short items. Use an empty array \
    when there are none. Never invent items.
    - actionItems: owner is a speaker label exactly as it appears in the \
    transcript. due is set only when a date or deadline was stated; \
    otherwise null. Never invent dates.
    - speakerNames: only names a speaker was called by or introduced \
    themselves with in the conversation, as {"label": "Speaker 2", "name": \
    "Priya"}. Never guess a name.
    - Use speaker labels exactly as given everywhere. "Me" is the person who \
    recorded the meeting.
    - If a Vocabulary line is present, spell those terms exactly as listed.
    - Write in the language the meeting was held in.
    """

    static func user(_ request: MeetingNotesRequest, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        var lines = [
            "Meeting date: \(formatter.string(from: request.startedAt))",
            "Duration: \(MeetingTime.minutes(request.duration)) min",
        ]
        if !request.vocabulary.isEmpty {
            lines.append("Vocabulary: \(request.vocabulary.joined(separator: ", "))")
        }
        lines.append("")
        lines.append("Transcript:")
        lines += request.utterances.map { "[\(MeetingTime.clock($0.start))] \($0.speaker): \($0.text)" }
        return lines.joined(separator: "\n")
    }
}
