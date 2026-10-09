import Foundation

enum MeetingNotesParser {

    static func parse(_ raw: String) throws -> MeetingNotes {
        guard let notes = LLMJSON.decode(MeetingNotes.self, from: raw) else {
            throw LLMError.badResponseShape(reason: "meeting notes were not a JSON object matching the schema")
        }
        return normalized(notes)
    }

    private static func normalized(_ notes: MeetingNotes) -> MeetingNotes {
        func list(_ items: [String]) -> [String] { items.map(\.trimmed).filter { !$0.isEmpty } }
        return MeetingNotes(
            title: notes.title.trimmed,
            summary: notes.summary.trimmed,
            keyPoints: list(notes.keyPoints),
            decisions: list(notes.decisions),
            actionItems: notes.actionItems.compactMap { item in
                let task = item.task.trimmed
                guard !task.isEmpty else { return nil }
                let due = item.due?.trimmed
                return .init(owner: item.owner.trimmed, task: task, due: (due?.isEmpty ?? true) ? nil : due)
            },
            openQuestions: list(notes.openQuestions),
            speakerNames: notes.speakerNames
                .map { .init(label: $0.label.trimmed, name: $0.name.trimmed) }
                .filter { !$0.label.isEmpty && !$0.name.isEmpty }
        )
    }
}
