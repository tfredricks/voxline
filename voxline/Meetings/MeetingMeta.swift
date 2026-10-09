import Foundation

enum MeetingState: String, Codable, Sendable {
    case recording, recorded, processing, done, failed

    var isUnfinished: Bool { self == .recording || self == .recorded || self == .processing }
}

/// The `meta.json` record for one meeting.
struct MeetingMeta: Codable, Equatable, Sendable {
    var id: UUID
    var state: MeetingState
    var startedAt: Date
    var durationSeconds: Double
    var systemTapStarted: Bool
    var title: String?
    var notesPath: String?
    var failureReason: String?
}
