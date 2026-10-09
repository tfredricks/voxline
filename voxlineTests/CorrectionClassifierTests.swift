import Testing
@testable import voxline

@Suite @MainActor struct CorrectionClassifierTests {

    private func classify(_ inserted: String, _ corrected: String, before: String = "") -> Classification {
        CorrectionClassifier.classify(inserted: inserted, corrected: corrected, before: before, dictionary: FakeWordDictionary())
    }

    @Test func learns_a_two_word_mishearing_of_an_unknown_name() {
        let result = classify("ask Cooper Nettis to review", "ask Kubernetes to review")
        #expect(result.vocabulary == ["Kubernetes"])
        #expect(!result.isStyleSignal)
        #expect(result.hunkCount == 1)
    }

    @Test func learns_a_segmentation_fix() {
        #expect(classify("the arg max model", "the Argmax model").vocabulary == ["Argmax"])
    }

    @Test func learns_an_internal_capital_even_when_known() {
        #expect(classify("send the Jason now", "send the JSON now").vocabulary == ["JSON"])
    }

    @Test func learns_a_capital_the_user_added_mid_sentence() {
        #expect(classify("ping clod about it", "ping Claude about it").vocabulary == ["Claude"])
    }

    @Test func a_whole_dictation_that_is_just_the_name_is_not_a_rewrite() {
        #expect(classify("Cooper Nettis", "Kubernetes").vocabulary == ["Kubernetes"])
        #expect(classify("ask Cooper Nettis", "ask Kubernetes").vocabulary == ["Kubernetes"])
    }

    @Test func dictionary_word_swaps_are_style() {
        for (old, new) in [("on Tuesday", "on Thursday"), ("there", "their")] {
            let result = classify(old, new)
            #expect(result.vocabulary.isEmpty, "\(old) → \(new)")
            #expect(result.isStyleSignal, "\(old) → \(new)")
        }
    }

    @Test func case_only_and_punctuation_only_are_style() {
        #expect(classify("slack", "Slack") == Classification(vocabulary: [], isStyleSignal: true, hunkCount: 1))
        #expect(classify("Thanks.", "Thanks") == Classification(vocabulary: [], isStyleSignal: true, hunkCount: 1))
    }

    @Test func a_heavy_rewrite_learns_nothing() {
        let result = classify("we could use the new pipeline", "use LangGraph")
        #expect(result.vocabulary.isEmpty)
        #expect(result.isStyleSignal)
        #expect(result.hunkCount == 2)
    }

    @Test func three_word_substitutions_are_style() {
        let result = classify("ask Cooper Nettis Jr to review", "ask Kubernetes to review")
        #expect(result.vocabulary.isEmpty)
        #expect(result.isStyleSignal)
    }

    @Test func mid_sentence_looks_into_the_text_before_the_region() {
        #expect(classify("clod about it", "Claude about it", before: "ping ").vocabulary == ["Claude"])
        #expect(classify("clod about it", "Claude about it", before: "Done. ").vocabulary.isEmpty)
        #expect(classify("clod about it", "Claude about it", before: "Done\n").vocabulary.isEmpty)
        #expect(classify("clod about it", "Claude about it").vocabulary.isEmpty)
    }

    @Test func an_unchanged_region_is_nothing() {
        #expect(classify("hi Bob", "hi Bob") == Classification())
    }

    @Test func a_region_over_the_token_cap_is_style_only() {
        let long = Array(repeating: "w", count: TokenDiff.maxTokens + 1).joined(separator: " ")
        let result = classify(long, long + " Kubernetes")
        #expect(result.vocabulary.isEmpty)
        #expect(result.isStyleSignal)
    }

    @Test func term_shape() {
        #expect(CorrectionClassifier.isTermShaped("Argmax"))
        #expect(CorrectionClassifier.isTermShaped("Hugging Face"))
        #expect(!CorrectionClassifier.isTermShaped("X"))
        #expect(!CorrectionClassifier.isTermShaped("2026"))
        #expect(!CorrectionClassifier.isTermShaped(String(repeating: "a", count: 41)))
    }

    @Test func spell_check_dictionary_knows_common_words() {
        let dictionary = SpellCheckDictionary()
        #expect(dictionary.isKnown("the"))
        #expect(!dictionary.isKnown("qzxvbnmw"))
    }
}
