import Testing
import Foundation
@testable import voxline

@Suite struct CleanupFastPathTests {

    @Test func max_words_is_six() {
        #expect(CleanupFastPath.maxWords == 6)
    }

    @Test func short_clean_utterance_is_skipped() {
        #expect(CleanupFastPath.shouldSkip("Sounds good."))
        #expect(CleanupFastPath.shouldSkip("Yes"))
    }

    @Test func exactly_six_words_is_skipped() {
        #expect(CleanupFastPath.shouldSkip("Let us meet at noon tomorrow"))
    }

    @Test func seven_words_is_not_skipped() {
        #expect(!CleanupFastPath.shouldSkip("Let us meet at noon tomorrow please"))
    }

    @Test func empty_and_whitespace_only_are_not_skipped() {
        #expect(!CleanupFastPath.shouldSkip(""))
        #expect(!CleanupFastPath.shouldSkip("   \n\t "))
    }

    @Test func filler_tokens_disable_the_skip() {
        for filler in ["um", "uh", "er", "ah", "hmm"] {
            #expect(!CleanupFastPath.shouldSkip("\(filler) sounds good"), "\(filler)")
        }
    }

    @Test func filler_phrases_disable_the_skip() {
        #expect(!CleanupFastPath.shouldSkip("you know what I think"))
        #expect(!CleanupFastPath.shouldSkip("I mean it works"))
    }

    @Test func filler_detection_ignores_case_and_surrounding_punctuation() {
        #expect(!CleanupFastPath.shouldSkip("Um, sounds good"))
        #expect(!CleanupFastPath.shouldSkip("Sounds good, uh."))
        #expect(!CleanupFastPath.shouldSkip("HMM..."))
        #expect(!CleanupFastPath.shouldSkip("Well, You, know, fine"))
        #expect(!CleanupFastPath.shouldSkip("I mean, sure"))
    }

    @Test func words_that_merely_contain_a_filler_are_still_skipped() {
        #expect(CleanupFastPath.shouldSkip("Umbrella ahead"))
        #expect(CleanupFastPath.shouldSkip("Your knowledge helps"))
        #expect(CleanupFastPath.shouldSkip("Hermes and ahab"))
    }

    @Test func phrase_words_apart_do_not_count_as_a_phrase() {
        #expect(CleanupFastPath.shouldSkip("You said I know it"))
        #expect(CleanupFastPath.shouldSkip("Know you mean business"))
    }

    @Test func words_are_counted_before_punctuation_stripping() {
        #expect(!CleanupFastPath.shouldSkip("one two three four five six seven"))
        #expect(CleanupFastPath.shouldSkip("one, two, three, four, five, six."))
    }
}
