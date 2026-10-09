import Foundation

/// The learned style one cleanup carries: the category's note and examples
/// of the user's writing in the same app.
struct LearnedStyle: Equatable, Sendable {
    let categoryName: String
    let note: String?
    let examples: [String]
}

/// Renders a `LearnedStyle` as the system-prompt paragraph that follows the
/// mode's style guidance. Pure.
enum LearnedStyleFormatter {

    static let exampleLimit = 400
    static let examplesHeader = "Examples of this user's own writing in this app. Match their voice; never copy their content:"

    static func noteHeader(categoryName: String) -> String {
        "Learned style for \(categoryName) (from this user's own past messages; follow it where it doesn't conflict with the rules above):"
    }

    /// nil when there is neither a note nor an example.
    static func paragraph(_ style: LearnedStyle) -> String? {
        var blocks: [String] = []
        if let note = style.note?.trimmed, !note.isEmpty {
            blocks.append(noteHeader(categoryName: style.categoryName) + "\n" + note)
        }
        if !style.examples.isEmpty {
            let lines = style.examples.map { "- \"\(ContextBlockFormatter.escape(clip($0)))\"" }
            blocks.append(examplesHeader + "\n" + lines.joined(separator: "\n"))
        }
        return blocks.isEmpty ? nil : blocks.joined(separator: "\n\n")
    }

    /// `text` cut to `limit` characters at its last whitespace, with "…".
    static func clip(_ text: String, limit: Int = exampleLimit) -> String {
        guard text.count > limit else { return text }
        let head = text.prefix(limit)
        let cut = head.lastIndex(where: \.isWhitespace).map { head[..<$0] } ?? head
        return cut.trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}
