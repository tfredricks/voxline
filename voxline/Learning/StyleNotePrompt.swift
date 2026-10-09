import Foundation

struct StyleNoteRequest: Equatable, Sendable {
    let categoryName: String
    let currentNote: String?
    /// Oldest first.
    let texts: [String]
    /// Oldest first.
    let pairs: [StylePair]
    let model: String
}

protocol StyleNoteGenerating: Sendable {
    /// A style note for one mode category, at most `LearningStore.noteCap` characters.
    func styleNote(_ request: StyleNoteRequest) async throws -> String
}

/// The style-note refresh prompt and its input caps. Pure.
enum StyleNotePrompt {

    static let textsBudget = 8_000
    static let pairsBudget = 6_000
    static let outputTokens = 400

    static func system(categoryName: String) -> String {
        """
        You describe one person's writing habits in \(categoryName) messages so a dictation cleaner can match them. \
        Write 3–6 short lines, under 80 words in all, each a concrete habit seen in several texts: contractions, \
        greetings and sign-offs, sentence length, capitalization, end punctuation, lists versus prose, emoji. \
        Corrections show what the user changed after dictation, so weight them highly. Never quote the texts or \
        include names, facts, or topics from them. Return only the lines.
        """
    }

    static func user(_ request: StyleNoteRequest) -> String {
        var parts: [String] = []
        if let note = request.currentNote, !note.isBlank {
            parts.append("Current note:\n\(note)")
        }
        let texts = request.texts.enumerated().map { "\($0.offset + 1). \"\(ContextBlockFormatter.escape($0.element))\"" }
        parts.append("Texts:\n" + texts.joined(separator: "\n"))
        if !request.pairs.isEmpty {
            let pairs = request.pairs.map {
                "\"\(ContextBlockFormatter.escape($0.before))\" → \"\(ContextBlockFormatter.escape($0.after))\""
            }
            parts.append("Corrections:\n" + pairs.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
    }

    /// The category's stored data under the caps: the newest texts and pairs
    /// (already cut to `LearningStore`'s caps on write), oldest dropped first
    /// until each fits its budget.
    static func request(category: ModeCategory, data: CategoryLearning, model: String) -> StyleNoteRequest {
        StyleNoteRequest(
            categoryName: category.displayName,
            currentNote: data.note,
            texts: newest(data.recentTexts.map(\.text), max: LearningStore.maxTexts, budget: textsBudget) { $0.utf16.count },
            pairs: newest(data.stylePairs, max: LearningStore.maxPairs, budget: pairsBudget) { $0.before.utf16.count + $0.after.utf16.count },
            model: model
        )
    }

    /// The last `max` of `items` (oldest first), then the oldest dropped
    /// until the sizes sum to at most `budget`.
    static func newest<T>(_ items: [T], max: Int, budget: Int, size: (T) -> Int) -> [T] {
        var kept = Array(items.suffix(max))
        var total = kept.reduce(0) { $0 + size($1) }
        while total > budget, !kept.isEmpty {
            total -= size(kept.removeFirst())
        }
        return kept
    }

    /// The reply trimmed and, past `LearningStore.noteCap` UTF-16 units, cut
    /// at its last line break before the cap (or at the cap). nil when empty.
    static func note(fromReply reply: String) -> String? {
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let head = LearningStore.capped(trimmed, LearningStore.noteCap)
        guard head != trimmed else { return trimmed }
        let cut = head.lastIndex(of: "\n").map { String(head[..<$0]) } ?? head
        return cut.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension LLMRequest {
    /// `StyleNotePrompt.outputTokens` plus `thinkingHeadroom`.
    static func styleNoteBudget(model: String) -> Int {
        StyleNotePrompt.outputTokens + thinkingHeadroom(for: model)
    }
}
