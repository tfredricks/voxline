import Foundation

enum MeetingAudioRetention: String, CaseIterable, Codable, Sendable {
    case dontKeep, days7, days14, days30, forever

    static let `default`: MeetingAudioRetention = .days14

    private static let day: TimeInterval = 86_400

    var keepsAudio: Bool { self != .dontKeep }

    /// How long a finished meeting's directory is kept. `dontKeep` deletes
    /// audio at the end of processing but keeps the transcript for
    /// Regenerate Notes for 14 days. Nil keeps it forever.
    var directoryLifetime: TimeInterval? {
        switch self {
        case .dontKeep: return 14 * Self.day
        case .days7:    return 7 * Self.day
        case .days14:   return 14 * Self.day
        case .days30:   return 30 * Self.day
        case .forever:  return nil
        }
    }

    var displayName: String {
        switch self {
        case .dontKeep: return "Don't keep"
        case .days7:    return "7 days"
        case .days14:   return "14 days"
        case .days30:   return "30 days"
        case .forever:  return "Forever"
        }
    }
}
