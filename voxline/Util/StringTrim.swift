import Foundation

extension String {
    /// Same as `trimmingCharacters(in: .whitespacesAndNewlines)`, but short
    /// enough to use inline at call sites without obscuring the surrounding
    /// expression.
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `true` when the string is empty after trimming surrounding whitespace
    /// and newlines. Used by Settings/Wizard validators that treat an
    /// all-whitespace API key or vocabulary entry as empty.
    var isBlank: Bool {
        trimmed.isEmpty
    }
}
