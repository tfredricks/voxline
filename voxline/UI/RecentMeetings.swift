import Foundation

struct RecentMeeting: Equatable, Identifiable {
    let id: UUID
    let title: String
    let startedAt: Date
    let durationSeconds: Double
    /// Nil when the meeting has no notes file or the file is gone.
    let notesURL: URL?
    /// Shown in place of the duration while a meeting isn't finished, or when it failed.
    let stageLabel: String?
    let showsRetry: Bool
}

enum RecentMeetings {
    static func rows(
        metas: [MeetingMeta],
        phase: MeetingController.Phase,
        lastFailed: UUID?,
        fileExists: (URL) -> Bool,
        limit: Int = 5
    ) -> [RecentMeeting] {
        metas
            .sorted { $0.startedAt > $1.startedAt }
            .prefix(limit)
            .map { meta in
                let notesURL = meta.notesPath
                    .map { URL(fileURLWithPath: $0) }
                    .flatMap { fileExists($0) ? $0 : nil }
                return RecentMeeting(
                    id: meta.id,
                    title: meta.title ?? MeetingMarkdown.untitled,
                    startedAt: meta.startedAt,
                    durationSeconds: meta.durationSeconds,
                    notesURL: notesURL,
                    stageLabel: stageLabel(meta.state, phase: phase),
                    showsRetry: meta.id == lastFailed
                )
            }
    }

    private static func stageLabel(_ state: MeetingState, phase: MeetingController.Phase) -> String? {
        switch state {
        case .done: return nil
        case .recording: return "Recording…"
        case .recorded: return "Waiting to process…"
        case .failed: return "Failed"
        case .processing:
            if case .processing(let stage) = phase { return stage?.label ?? "Processing…" }
            return "Processing…"
        }
    }
}
