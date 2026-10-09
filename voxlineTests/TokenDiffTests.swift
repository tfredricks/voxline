import Testing
@testable import voxline

@Suite struct TokenDiffTests {

    private func solid(_ text: String) -> [Token] {
        WordTokenizer.tokens(text).filter { $0.kind != .space }
    }

    private func diff(_ old: String, _ new: String) -> [Hunk]? {
        TokenDiff.hunks(old: solid(old), new: solid(new))
    }

    @Test func equal_text_has_no_hunks() {
        #expect(diff("send the JSON now", "send the JSON now") == [])
    }

    @Test func substitution() {
        #expect(diff("send the Jason now", "send the JSON now") == [Hunk(old: 2..<3, new: 2..<3)])
    }

    @Test func two_words_merged_into_one() {
        #expect(diff("ask Cooper Nettis to review", "ask Kubernetes to review") == [Hunk(old: 1..<3, new: 1..<2)])
    }

    @Test func insertion() {
        #expect(diff("hi there", "hi over there") == [Hunk(old: 1..<1, new: 1..<2)])
    }

    @Test func deletion() {
        #expect(diff("we could use it", "use it") == [Hunk(old: 0..<2, new: 0..<0)])
    }

    @Test func separate_hunks() {
        #expect(diff("a b c d", "a x c y") == [Hunk(old: 1..<2, new: 1..<2), Hunk(old: 3..<4, new: 3..<4)])
    }

    @Test func punctuation_is_its_own_token() {
        #expect(diff("Thanks.", "Thanks") == [Hunk(old: 1..<2, new: 1..<1)])
    }

    @Test func more_than_the_cap_is_nil() {
        let long = Array(repeating: "w", count: TokenDiff.maxTokens + 1).joined(separator: " ")
        #expect(diff(long, "w") == nil)
        #expect(diff("w", long) == nil)
    }
}
