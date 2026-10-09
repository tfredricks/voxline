import Foundation
import Testing
@testable import voxline

@Suite struct CommandResultParserTests {

    private func parseError(_ raw: String) -> LLMError? {
        do {
            _ = try CommandResultParser.parse(raw)
            return nil
        } catch let error as LLMError {
            return error
        } catch {
            Issue.record("expected LLMError, got \(error)")
            return nil
        }
    }

    private let notAnObject = LLMError.badResponseShape(reason: "command result was not a JSON object with action and text")

    @Test func parses_a_valid_object() throws {
        let result = try CommandResultParser.parse(#"{"action":"insert","text":"hi"}"#)
        #expect(result == CommandResult(action: .insert, text: "hi"))
    }

    @Test func parses_every_action() throws {
        for action in CommandAction.allCases {
            let result = try CommandResultParser.parse(#"{"action":"\#(action.rawValue)","text":"x"}"#)
            #expect(result.action == action)
        }
    }

    @Test func parses_surrounding_whitespace() throws {
        let result = try CommandResultParser.parse("\n  {\"action\":\"insert\",\"text\":\"hi\"}  \n")
        #expect(result == CommandResult(action: .insert, text: "hi"))
    }

    @Test func parses_empty_text() throws {
        let result = try CommandResultParser.parse(#"{"action":"replace_selection","text":""}"#)
        #expect(result == CommandResult(action: .replaceSelection, text: ""))
    }

    @Test func ignores_extra_keys() throws {
        let result = try CommandResultParser.parse(#"{"action":"insert","text":"hi","note":"extra"}"#)
        #expect(result == CommandResult(action: .insert, text: "hi"))
    }

    @Test func parses_a_json_fenced_object() throws {
        let raw = "```json\n{\"action\":\"replace_selection\",\"text\":\"Hola\"}\n```"
        #expect(try CommandResultParser.parse(raw) == CommandResult(action: .replaceSelection, text: "Hola"))
    }

    @Test func parses_a_bare_fenced_object() throws {
        let raw = "```\n{\"action\":\"insert\",\"text\":\"a\\nb\"}\n```"
        #expect(try CommandResultParser.parse(raw) == CommandResult(action: .insert, text: "a\nb"))
    }

    @Test func parses_a_single_line_fence() throws {
        let raw = "```json {\"action\":\"insert\",\"text\":\"hi\"} ```"
        #expect(try CommandResultParser.parse(raw) == CommandResult(action: .insert, text: "hi"))
    }

    @Test func parses_an_object_wrapped_in_prose() throws {
        let result = try CommandResultParser.parse(#"Sure! {"action":"rewrite","text":"x"} Done."#)
        #expect(result == CommandResult(action: .rewrite, text: "x"))
    }

    @Test func wrapped_object_keeps_braces_inside_text() throws {
        let result = try CommandResultParser.parse(#"Here: {"action":"insert","text":"if (a) { b() }"} ok"#)
        #expect(result == CommandResult(action: .insert, text: "if (a) { b() }"))
    }

    @Test func malformed_input_throws_bad_response_shape() {
        #expect(parseError("not json") == notAnObject)
        #expect(parseError("") == notAnObject)
        #expect(parseError("{\"action\":\"insert\",") == notAnObject)
    }

    @Test func missing_text_throws() {
        #expect(parseError(#"{"action":"insert"}"#) == notAnObject)
    }

    @Test func non_string_text_throws() {
        #expect(parseError(#"{"action":"insert","text":null}"#) == notAnObject)
        #expect(parseError(#"{"action":"insert","text":3}"#) == notAnObject)
    }

    @Test func unknown_action_throws_with_its_name() throws {
        let error = try #require(parseError(#"{"action":"delete","text":""}"#))
        #expect(error == .badResponseShape(reason: "unknown action \"delete\""))
        guard case .badResponseShape(let reason) = error else { return }
        #expect(reason.contains("unknown action"))
    }

    @Test func schema_json_is_a_strict_object_with_action_and_text() throws {
        let object = try JSONSerialization.jsonObject(with: Data(CommandResult.schemaJSON.utf8))
        let schema = try #require(object as? [String: Any])
        #expect(schema["type"] as? String == "object")
        #expect(schema["required"] as? [String] == ["action", "text"])
        #expect(schema["additionalProperties"] as? Bool == false)

        let properties = try #require(schema["properties"] as? [String: Any])
        let action = try #require(properties["action"] as? [String: Any])
        #expect(action["type"] as? String == "string")
        #expect(action["enum"] as? [String] == CommandAction.allCases.map(\.rawValue))
        let text = try #require(properties["text"] as? [String: Any])
        #expect(text["type"] as? String == "string")
    }
}
