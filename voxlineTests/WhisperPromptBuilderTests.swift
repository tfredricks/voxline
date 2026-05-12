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

    @Test func promptString_joins_terms_with_comma_space_and_trailing_period() {
        let s = WhisperPromptBuilder.promptString(from: ["Argmax", "LangGraph", "MSL"])
        #expect(s == "Argmax, LangGraph, MSL.")
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
            budget: 10
        )
        // Per-char ASCII: 'A'=65, ','=44, ' '=32, 'B'=66, '.'=46.
        // Builder keeps first two terms → "AAA, BBB." → 9 tokens, fits in 10.
        #expect(tokens == [65, 65, 65, 44, 32, 66, 66, 66, 46])
    }

    @Test func promptTokens_filters_special_token_ids() {
        // "Argmax." override (the actual joined string the builder hands to
        // the tokenizer) emits one special-token ID (99999) and two normals.
        // Builder must drop the 99999.
        var t = FakeTokenizer()
        t.overrides["Argmax."] = [99_999, 65, 66]
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
}
