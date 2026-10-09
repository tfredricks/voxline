import Foundation
import Testing
@testable import voxline

@Suite struct MeetingNotesParserTests {

    private let valid = """
    {"title":" Q4 pricing ","summary":"We agreed on pricing.","keyPoints":["Discount asked"," "],"decisions":["Eight percent"],\
    "actionItems":[{"owner":"Me","task":"Send quote","due":"Friday"},{"owner":"Speaker 2","task":"Confirm seats","due":" "}],\
    "openQuestions":[],"speakerNames":[{"label":"Speaker 2","name":"Priya"},{"label":"Speaker 1","name":""}]}
    """

    @Test func parses_and_normalizes() throws {
        let notes = try MeetingNotesParser.parse(valid)
        #expect(notes.title == "Q4 pricing")
        #expect(notes.keyPoints == ["Discount asked"])
        #expect(notes.actionItems[0].due == "Friday")
        #expect(notes.actionItems[1].due == nil)
        #expect(notes.speakerNames == [MeetingNotes.SpeakerName(label: "Speaker 2", name: "Priya")])
    }

    @Test func accepts_fenced_json() throws {
        let notes = try MeetingNotesParser.parse("```json\n\(valid)\n```")
        #expect(notes.decisions == ["Eight percent"])
    }

    @Test func accepts_null_due() throws {
        let raw = valid.replacingOccurrences(of: #""due":"Friday""#, with: #""due":null"#)
        #expect(try MeetingNotesParser.parse(raw).actionItems[0].due == nil)
    }

    @Test func rejects_non_json() {
        #expect(throws: LLMError.self) { try MeetingNotesParser.parse("Here are your notes: …") }
    }

    @Test func schema_is_valid_json_with_strict_objects() throws {
        let schema = try #require(JSONSerialization.jsonObject(with: Data(MeetingNotes.schemaJSON.utf8)) as? [String: Any])
        #expect(schema["additionalProperties"] as? Bool == false)
        let required = try #require(schema["required"] as? [String])
        #expect(Set(required) == ["title", "summary", "keyPoints", "decisions", "actionItems", "openQuestions", "speakerNames"])
    }
}
