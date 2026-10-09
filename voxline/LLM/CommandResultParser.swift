import Foundation

enum CommandResultParser {
    private struct Raw: Decodable {
        let action: String
        let text: String
    }

    /// Decodes `{action, text}`; failing that, strips code fences and decodes
    /// the span from the first `{` to the last `}`. Anything else, including
    /// an unknown action, throws `LLMError.badResponseShape`.
    static func parse(_ raw: String) throws -> CommandResult {
        guard let decoded = LLMJSON.decode(Raw.self, from: raw) else {
            throw LLMError.badResponseShape(reason: "command result was not a JSON object with action and text")
        }
        guard let action = CommandAction(rawValue: decoded.action) else {
            throw LLMError.badResponseShape(reason: "unknown action \"\(decoded.action)\"")
        }
        return CommandResult(action: action, text: decoded.text)
    }
}
