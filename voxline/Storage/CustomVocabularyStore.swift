import Foundation

/// Global custom-vocabulary list. Plain `[String]` persisted to UserDefaults.
/// Intentionally minimal: this is a stub for feature #9, which will replace it
/// with per-mode dictionaries. `load()` is called once per dictation; keep it
/// fast (single defaults read).
///
/// `@unchecked Sendable` mirrors `AppSettings`: `UserDefaults` isn't formally
/// `Sendable` but is documented thread-safe, and this struct holds no other
/// shared mutable state.
struct CustomVocabularyStore: @unchecked Sendable {

    private static let key = "voxline.context.customVocabulary"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> [String] {
        defaults.stringArray(forKey: Self.key) ?? []
    }

    /// Persist `terms` after trimming whitespace, dropping empties, and
    /// deduping while preserving insertion order. Case-sensitive dedupe —
    /// users may want both `cursor` (CLI) and `Cursor` (editor).
    func save(_ terms: [String]) {
        let cleaned = Self.normalize(terms)
        defaults.set(cleaned, forKey: Self.key)
    }

    /// Convert the Settings text field's contents (comma- or newline-separated)
    /// into a list. Same normalization rules as `save`.
    static func parse(_ text: String) -> [String] {
        // Accept all newline variants (\n, \r\n, \r, U+2028, U+2029) so paste
        // from Windows or other-platform text editors doesn't smuggle \r into
        // a term name.
        let separators = CharacterSet(charactersIn: ",").union(.newlines)
        let pieces = text.components(separatedBy: separators)
        return normalize(pieces)
    }

    private static func normalize(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in terms {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { continue }
            if seen.insert(t).inserted { out.append(t) }
        }
        return out
    }
}
