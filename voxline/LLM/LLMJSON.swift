import Foundation

/// Decodes a JSON object from a model reply that may wrap it in code fences
/// or prose.
enum LLMJSON {

    static func decode<T: Decodable>(_ type: T.Type, from raw: String) -> T? {
        let trimmed = raw.trimmed
        return decodeExactly(type, trimmed) ?? objectSpan(in: stripFences(trimmed)).flatMap { decodeExactly(type, $0) }
    }

    private static func decodeExactly<T: Decodable>(_ type: T.Type, _ json: String) -> T? {
        try? JSONDecoder().decode(type, from: Data(json.utf8))
    }

    static func stripFences(_ text: String) -> String {
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

    static func objectSpan(in text: String) -> String? {
        guard let open = text.firstIndex(of: "{"),
              let close = text.lastIndex(of: "}"),
              open < close else { return nil }
        return String(text[open ... close])
    }
}
