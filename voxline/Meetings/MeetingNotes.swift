import Foundation

struct MeetingNotes: Codable, Equatable, Sendable {

    struct ActionItem: Codable, Equatable, Sendable {
        var owner: String
        var task: String
        var due: String?
    }

    /// A name the conversation itself gave a speaker label.
    struct SpeakerName: Codable, Equatable, Sendable {
        var label: String
        var name: String
    }

    var title: String
    var summary: String
    var keyPoints: [String]
    var decisions: [String]
    var actionItems: [ActionItem]
    var openQuestions: [String]
    var speakerNames: [SpeakerName]

    static let schemaJSON = """
    {"type":"object","additionalProperties":false,"required":["title","summary","keyPoints","decisions","actionItems","openQuestions","speakerNames"],"properties":{"title":{"type":"string"},"summary":{"type":"string"},"keyPoints":{"type":"array","items":{"type":"string"}},"decisions":{"type":"array","items":{"type":"string"}},"actionItems":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["owner","task","due"],"properties":{"owner":{"type":"string"},"task":{"type":"string"},"due":{"type":["string","null"]}}}},"openQuestions":{"type":"array","items":{"type":"string"}},"speakerNames":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["label","name"],"properties":{"label":{"type":"string"},"name":{"type":"string"}}}}}}
    """
}

extension MeetingNotes {
    /// `title` and `summary` are required; a missing list decodes as empty,
    /// so prompt-only output that omits a section still parses.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        summary = try container.decode(String.self, forKey: .summary)
        keyPoints = try container.decodeIfPresent([String].self, forKey: .keyPoints) ?? []
        decisions = try container.decodeIfPresent([String].self, forKey: .decisions) ?? []
        actionItems = try container.decodeIfPresent([ActionItem].self, forKey: .actionItems) ?? []
        openQuestions = try container.decodeIfPresent([String].self, forKey: .openQuestions) ?? []
        speakerNames = try container.decodeIfPresent([SpeakerName].self, forKey: .speakerNames) ?? []
    }
}

struct MeetingNotesRequest: Equatable, Sendable {
    var model: String
    var utterances: [MeetingUtterance]
    var startedAt: Date
    var duration: TimeInterval
    var vocabulary: [String]
}

protocol MeetingNotesGenerating: Sendable {
    func meetingNotes(_ request: MeetingNotesRequest) async throws -> MeetingNotes
}
