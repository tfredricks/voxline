import Foundation

/// Global custom-vocabulary list. Plain `[String]` persisted to UserDefaults.
/// `@unchecked Sendable`: its only state is a `UserDefaults`, which is documented thread-safe.
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
        defaults.set(Self.normalize(terms), forKey: Self.key)
    }

    private static func normalize(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in terms {
            let t = raw.trimmed
            if t.isEmpty { continue }
            if seen.insert(t).inserted { out.append(t) }
        }
        return out
    }
}
