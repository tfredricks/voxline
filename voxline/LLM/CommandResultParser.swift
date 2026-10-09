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
        let trimmed = raw.trimmed
        guard let decoded = decode(trimmed) ?? objectSpan(in: stripFences(trimmed)).flatMap(decode) else {
            throw LLMError.badResponseShape(reason: "command result was not a JSON object with action and text")
        }
        guard let action = CommandAction(rawValue: decoded.action) else {
            throw LLMError.badResponseShape(reason: "unknown action \"\(decoded.action)\"")
        }
        return CommandResult(action: action, text: decoded.text)
    }

    private static func decode(_ json: String) -> Raw? {
        try? JSONDecoder().decode(Raw.self, from: Data(json.utf8))
    }

    private static func stripFences(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        guard lines.count > 1 else { return text }
        if let first = lines.first, first.trimmed.hasPrefix("```") {
            lines.removeFirst()
        }
        if let last = lines.last, last.trimmed == "```" {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    private static func objectSpan(in text: String) -> String? {
        guard let open = text.firstIndex(of: "{"),
              let close = text.lastIndex(of: "}"),
              open < close else { return nil }
        return String(text[open ... close])
    }
}
