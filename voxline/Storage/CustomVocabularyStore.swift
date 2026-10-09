import Foundation

enum VocabularySource: String, Sendable {
    case user, learned
}

struct VocabularyEntry: Equatable, Sendable {
    let term: String
    let source: VocabularySource
}

/// Global custom-vocabulary list. Plain `[String]` persisted to UserDefaults,
/// with a sidecar list naming the terms Learning added. A term not in the
/// sidecar is the user's, so lists saved before Learning load unchanged.
/// UserDefaults is documented thread-safe, so this struct (held by the
/// `Sendable`-conforming `DefaultContextCaptureService`) is safe across actors.
struct CustomVocabularyStore {

    private static let key = "voxline.context.customVocabulary"
    private static let learnedKey = "voxline.context.learnedVocabulary"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> [String] {
        defaults.stringArray(forKey: Self.key) ?? []
    }

    /// Persist `terms` after trimming whitespace, dropping empties, and
    /// deduping while preserving insertion order. Case-sensitive dedupe —
    /// users may want both `cursor` (CLI) and `Cursor` (editor). Learned
    /// marks for terms no longer listed are dropped.
    func save(_ terms: [String]) {
        let cleaned = Self.normalize(terms)
        defaults.set(cleaned, forKey: Self.key)
        let kept = Set(cleaned)
        let learned = learnedTerms().filter(kept.contains)
        if learned.isEmpty {
            defaults.removeObject(forKey: Self.learnedKey)
        } else {
            defaults.set(learned, forKey: Self.learnedKey)
        }
    }

    func entries() -> [VocabularyEntry] {
        let learned = Set(learnedTerms())
        return load().map { VocabularyEntry(term: $0, source: learned.contains($0) ? .learned : .user) }
    }

    /// Appends `term` as learned unless it is blank or the list already
    /// holds it in any case. Returns whether it was added.
    @discardableResult
    func addLearned(_ term: String) -> Bool {
        let trimmed = term.trimmed
        let terms = load()
        guard !trimmed.isEmpty,
              !terms.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return false }
        save(terms + [trimmed])
        defaults.set(learnedTerms() + [trimmed], forKey: Self.learnedKey)
        return true
    }

    @discardableResult
    func remove(_ term: String) -> VocabularyEntry? {
        guard let entry = entries().first(where: { $0.term == term }) else { return nil }
        save(load().filter { $0 != term })
        return entry
    }

    @discardableResult
    func removeAll() -> [VocabularyEntry] {
        let all = entries()
        save([])
        return all
    }

    /// Removes the learned terms, keeping the user's. Returns what it removed.
    @discardableResult
    func removeLearned() -> [String] {
        let learned = entries().filter { $0.source == .learned }.map(\.term)
        save(load().filter { !learned.contains($0) })
        return learned
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

    private func learnedTerms() -> [String] {
        defaults.stringArray(forKey: Self.learnedKey) ?? []
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
