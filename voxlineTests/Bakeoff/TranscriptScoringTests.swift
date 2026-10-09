import Testing
@testable import voxline

@Suite struct TranscriptScoringTests {

    // MARK: normalizedWords

    @Test func normalizedWords_lowercases_and_strips_punctuation() {
        #expect(TranscriptScoring.normalizedWords("Hello, World! Done.") == ["hello", "world", "done"])
    }

    @Test func normalizedWords_keeps_apostrophes_and_digits() {
        #expect(TranscriptScoring.normalizedWords("Don't ship v2 at 5pm") == ["don't", "ship", "v2", "at", "5pm"])
    }

    @Test func normalizedWords_treats_curly_apostrophes_as_straight() {
        #expect(TranscriptScoring.normalizedWords("don\u{2019}t") == ["don't"])
    }

    @Test func normalizedWords_splits_on_hyphens_and_any_whitespace() {
        #expect(TranscriptScoring.normalizedWords("state-of-the-art\n\tmodel  ") == ["state", "of", "the", "art", "model"])
    }

    @Test func normalizedWords_of_blank_or_punctuation_only_input_is_empty() {
        #expect(TranscriptScoring.normalizedWords("").isEmpty)
        #expect(TranscriptScoring.normalizedWords(" ... !? ").isEmpty)
    }

    // MARK: wordErrorRate

    @Test func wer_of_identical_text_is_zero() {
        #expect(TranscriptScoring.wordErrorRate(reference: "the quick brown fox", hypothesis: "the quick brown fox") == 0)
    }

    @Test func wer_counts_one_substitution_in_four_words() {
        #expect(TranscriptScoring.wordErrorRate(reference: "the quick brown fox", hypothesis: "the quick brown box") == 0.25)
    }

    @Test func wer_counts_one_deletion_in_four_words() {
        #expect(TranscriptScoring.wordErrorRate(reference: "the quick brown fox", hypothesis: "the quick fox") == 0.25)
    }

    @Test func wer_counts_one_insertion_in_four_words() {
        #expect(TranscriptScoring.wordErrorRate(reference: "the quick brown fox", hypothesis: "the very quick brown fox") == 0.25)
    }

    @Test func wer_ignores_punctuation_and_case() {
        #expect(TranscriptScoring.wordErrorRate(reference: "Hello, world. It's me!", hypothesis: "hello world its me") == 0.25)
        #expect(TranscriptScoring.wordErrorRate(reference: "Hello, world. It's me!", hypothesis: "HELLO WORLD... It's me") == 0)
    }

    @Test func wer_of_two_empty_strings_is_zero() {
        #expect(TranscriptScoring.wordErrorRate(reference: "", hypothesis: "") == 0)
        #expect(TranscriptScoring.wordErrorRate(reference: "...", hypothesis: " ") == 0)
    }

    @Test func wer_with_empty_reference_and_nonempty_hypothesis_is_one() {
        #expect(TranscriptScoring.wordErrorRate(reference: "", hypothesis: "stray words") == 1)
    }

    @Test func wer_with_empty_hypothesis_is_one() {
        #expect(TranscriptScoring.wordErrorRate(reference: "all gone", hypothesis: "") == 1)
    }

    @Test func wer_can_exceed_one_when_the_hypothesis_is_much_longer() {
        #expect(TranscriptScoring.wordErrorRate(reference: "hi", hypothesis: "hi there my good friend") == 4)
    }

    @Test func wordEdits_reports_distance_and_reference_length() {
        let edits = TranscriptScoring.wordEdits(reference: "a b c d", hypothesis: "a x c")
        #expect(edits.distance == 2)
        #expect(edits.referenceCount == 4)
    }

    // MARK: compact and termHits

    @Test func compact_keeps_only_lowercase_letters_and_digits() {
        #expect(TranscriptScoring.compact("Lang-Graph 2.0!") == "langgraph20")
    }

    @Test func termHits_matches_across_spacing_and_case() {
        let hits = TranscriptScoring.termHits(
            term: "LangGraph",
            reference: "I use LangGraph daily",
            hypothesis: "I use lang graph daily"
        )
        #expect(hits.inReference == 1)
        #expect(hits.hits == 1)
    }

    @Test func termHits_misses_a_misheard_term() {
        let hits = TranscriptScoring.termHits(
            term: "LangGraph",
            reference: "I use LangGraph daily",
            hypothesis: "I use land graph daily"
        )
        #expect(hits.inReference == 1)
        #expect(hits.hits == 0)
    }

    @Test func termHits_is_capped_by_the_reference_count() {
        let hits = TranscriptScoring.termHits(
            term: "Argmax",
            reference: "Argmax ships it",
            hypothesis: "Argmax ships Argmax it"
        )
        #expect(hits.inReference == 1)
        #expect(hits.hits == 1)
    }

    @Test func termHits_counts_each_occurrence() {
        let hits = TranscriptScoring.termHits(
            term: "Kubernetes",
            reference: "Kubernetes and Kubernetes again",
            hypothesis: "Kubernetes and communities again"
        )
        #expect(hits.inReference == 2)
        #expect(hits.hits == 1)
    }

    @Test func termHits_counts_non_overlapping_occurrences() {
        let hits = TranscriptScoring.termHits(term: "aa", reference: "aaa", hypothesis: "aaaa")
        #expect(hits.inReference == 1)
        #expect(hits.hits == 1)
        let more = TranscriptScoring.termHits(term: "aa", reference: "aaaa", hypothesis: "aaaa")
        #expect(more.inReference == 2)
        #expect(more.hits == 2)
    }

    @Test func termHits_of_a_term_with_no_letters_or_digits_is_zero() {
        let hits = TranscriptScoring.termHits(term: "--", reference: "a--b", hypothesis: "a--b")
        #expect(hits.inReference == 0)
        #expect(hits.hits == 0)
    }

    // MARK: median and percentile

    @Test func median_of_odd_and_even_counts() {
        #expect(TranscriptScoring.median([30, 10, 20]) == 20)
        #expect(TranscriptScoring.median([10, 20, 30, 41]) == 25)
    }

    @Test func median_of_nothing_is_zero() {
        #expect(TranscriptScoring.median([]) == 0)
    }

    @Test func percentile_uses_nearest_rank() {
        let values = Array(1...10)
        #expect(TranscriptScoring.percentile(values, 0.9) == 9)
        #expect(TranscriptScoring.percentile(values, 1.0) == 10)
        #expect(TranscriptScoring.percentile([7], 0.9) == 7)
        #expect(TranscriptScoring.percentile([], 0.9) == 0)
    }
}
