import Testing
import Foundation
@testable import voxline

/// Tests for WhisperPromptBuilder. Uses a fake tokenizer so the suite has no
/// dependency on WhisperKit weights — each character maps to a deterministic
/// token ID, and `,` plus ` ` are given dedicated IDs so we can assert
/// joining behavior precisely.
@Suite struct WhisperPromptBuilderTests {

    /// Deterministic fake. Each Character maps to its Unicode scalar value
    /// as the token ID. Unrecognized strings tokenize to nothing. Special-
    /// token threshold is 50000 so any ID below that is a "normal" token.
    struct FakeTokenizer: VocabularyTokenizing {
        var specialTokenBegin: Int = 50_000
        /// Optional override: terms whose tokenization should include a
        /// special-token ID. Maps a term to the IDs it should produce.
        var overrides: [String: [Int]] = [:]
        func encode(text: String) -> [Int] {
            if let override = overrides[text] { return override }
            return text.unicodeScalars.map { Int($0.value) }
        }
    }

    @Test func promptString_has_leading_space_comma_space_no_trailing_punctuation() {
        let s = WhisperPromptBuilder.promptString(from: ["Argmax", "LangGraph", "MSL"])
        #expect(s == " Argmax, LangGraph, MSL")
    }

    @Test func promptString_returns_empty_when_no_terms() {
        let s = WhisperPromptBuilder.promptString(from: [])
        #expect(s == "")
    }

    @Test func promptTokens_returns_empty_when_no_terms() {
        let tokens = WhisperPromptBuilder.promptTokens(from: [], tokenizer: FakeTokenizer())
        #expect(tokens.isEmpty)
    }

    @Test func promptTokens_truncates_from_tail_when_over_budget() {
        let tokens = WhisperPromptBuilder.promptTokens(
            from: ["AAA", "BBB", "CCC"],
            tokenizer: FakeTokenizer(),
            budget: 9
        )
        // Per-char ASCII: ' '=32, 'A'=65, ','=44, 'B'=66.
        // Leading space, no trailing period. Builder keeps first two terms
        // → " AAA, BBB" → 9 tokens, fits in 9. Adding "CCC" would make
        // " AAA, BBB, CCC" = 14 tokens, over budget → dropped.
        #expect(tokens == [32, 65, 65, 65, 44, 32, 66, 66, 66])
    }

    @Test func promptTokens_filters_special_token_ids() {
        // " Argmax" override (the actual joined string the builder now hands
        // to the tokenizer — note the leading space) emits one special-token
        // ID (99999) and two normals. Builder must drop the 99999.
        var t = FakeTokenizer()
        t.overrides[" Argmax"] = [99_999, 65, 66]
        let tokens = WhisperPromptBuilder.promptTokens(from: ["Argmax"], tokenizer: t, budget: 100)
        #expect(!tokens.contains(99_999))
        #expect(tokens.contains(65))
        #expect(tokens.contains(66))
    }

    @Test func tokenCount_matches_promptTokens_length_when_under_budget() {
        let t = FakeTokenizer()
        let terms = ["Argmax", "MSL"]
        let count = WhisperPromptBuilder.tokenCount(of: terms, tokenizer: t)
        let tokens = WhisperPromptBuilder.promptTokens(from: terms, tokenizer: t, budget: 1_000)
        #expect(count == tokens.count)
    }

    @Test func promptTokens_returns_empty_when_single_term_exceeds_budget() {
        // "AAAAA" → 5 chars → 5 tokens (per-char fake). Budget 3 → the
        // first (and only) candidate already overflows, so no terms are
        // kept and the builder returns []. Confirms we never byte-truncate
        // a term to fit.
        let tokens = WhisperPromptBuilder.promptTokens(
            from: ["AAAAA"],
            tokenizer: FakeTokenizer(),
            budget: 3
        )
        #expect(tokens.isEmpty)
    }

    @Test func tokenCount_does_not_apply_budget() {
        // The same input that promptTokens would truncate to [] under a
        // tight budget should produce its full token count when measured
        // via tokenCount, which has no budget concept.
        let t = FakeTokenizer()
        let terms = ["AAA", "BBB", "CCC"]
        // Budget 2: even the first term "AAA" (3 tokens) overflows, so the
        // builder returns []. Counter is unbudgeted, so it returns 13.
        let truncated = WhisperPromptBuilder.promptTokens(from: terms, tokenizer: t, budget: 2)
        let count = WhisperPromptBuilder.tokenCount(of: terms, tokenizer: t)
        #expect(truncated.isEmpty)
        // " AAA, BBB, CCC" per-char ASCII → 14 tokens total (leading space,
        // no trailing period).
        #expect(count == 14)
    }
}
