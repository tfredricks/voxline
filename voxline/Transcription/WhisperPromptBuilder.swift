import Foundation

/// Minimal tokenizer interface that `WhisperPromptBuilder` depends on. Two
/// reasons for the local protocol rather than `WhisperTokenizer` directly:
/// (1) tests can substitute a deterministic fake without pulling WhisperKit
/// into the test target's link graph, and (2) the builder doesn't need the
/// 6-method `WhisperTokenizer` surface — only `encode(text:)` and the
/// special-token threshold.
protocol VocabularyTokenizing {
    /// First token ID at or above which a token is special (e.g. language
    /// tokens, timestamps, end-of-text). Tokens >= this threshold are filtered
    /// out of the prompt by WhisperKit itself; we do the same so our token
    /// count matches what's actually consumed.
    var specialTokenBegin: Int { get }
    func encode(text: String) -> [Int]
}

/// Builds the `promptTokens` array for `DecodingOptions` from a flat list of
/// canonical vocabulary terms. Pure functions; no state.
enum WhisperPromptBuilder {

    /// WhisperKit's internal cap on `promptTokens` is `(maxTokenContext / 2) - 1`
    /// where `Constants.maxTokenContext` is **224** (half of the model's 448
    /// context budget, see `Models.swift:1334`). That gives a hard ceiling of
    /// 111 tokens; over that, WhisperKit silently `.suffix`-truncates and may
    /// slice a term mid-token. We cap at 100 so the UI counter agrees with
    /// what's actually used and to leave headroom for the `<|startofprev|>`
    /// marker WhisperKit prepends to our list.
    static let promptTokenBudget = 100

    /// Comma-space joiner with NO trailing punctuation.
    ///
    /// `<|startofprev|> Argmax, LangGraph` reads to the decoder as "the
    /// previous segment was a still-open list of names." `<|startofprev|>
    /// Argmax, LangGraph.` reads as "the previous segment was a *complete
    /// statement*, the new audio is what came next" — and Whisper interprets
    /// short dictation audio as post-statement silence, producing empty
    /// output. Empirically the period was a hard-fail; the open-list form
    /// biases vocabulary without that side effect.
    static func promptString(from terms: [String]) -> String {
        guard !terms.isEmpty else { return "" }
        return terms.joined(separator: ", ")
    }

    /// Tokenize the joined-term string, drop any special-token IDs, and
    /// truncate to the budget by removing terms from the tail.
    static func promptTokens(
        from terms: [String],
        tokenizer: VocabularyTokenizing,
        budget: Int = promptTokenBudget
    ) -> [Int] {
        guard !terms.isEmpty else { return [] }
        var kept: [String] = []
        for term in terms {
            let candidate = kept + [term]
            let tokens = filteredTokens(for: promptString(from: candidate), tokenizer: tokenizer)
            if tokens.count > budget { break }
            kept.append(term)
        }
        return filteredTokens(for: promptString(from: kept), tokenizer: tokenizer)
    }

    /// Live count for the Settings UI. Same path as `promptTokens` so the
    /// number matches what transcribe will actually use. No budget cap is
    /// applied here — the caller decides what to do with an over-budget
    /// number.
    static func tokenCount(of terms: [String], tokenizer: VocabularyTokenizing) -> Int {
        filteredTokens(for: promptString(from: terms), tokenizer: tokenizer).count
    }

    private static func filteredTokens(for text: String, tokenizer: VocabularyTokenizing) -> [Int] {
        guard !text.isEmpty else { return [] }
        return tokenizer.encode(text: text).filter { $0 < tokenizer.specialTokenBegin }
    }
}
