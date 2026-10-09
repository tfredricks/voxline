import Testing
@testable import voxline

@Suite struct WordTokenizerTests {

    private func shape(_ text: String) -> [String] {
        WordTokenizer.tokens(text).map { token in
            switch token.kind {
            case .word: return "w:\(token.text)"
            case .space: return "s"
            case .punctuation: return "p:\(token.text)"
            }
        }
    }

    @Test func joiners_inside_a_word_keep_it_whole() {
        #expect(shape("don't use Node.js, e-mail.") == [
            "w:don't", "s", "w:use", "s", "w:Node.js", "p:,", "s", "w:e-mail", "p:.",
        ])
        #expect(shape("snake_case x.y") == ["w:snake_case", "s", "w:x.y"])
    }

    @Test func a_period_before_a_line_break_is_punctuation() {
        #expect(shape("end.\nNext") == ["w:end", "p:.", "s", "w:Next"])
    }

    @Test func whitespace_runs_are_one_token() {
        #expect(shape("a  \n b") == ["w:a", "s", "w:b"])
        #expect(WordTokenizer.tokens("a  \n b")[1].text == "  \n ")
    }

    @Test func ranges_are_utf16_offsets() {
        let tokens = WordTokenizer.tokens("a 👍 b")
        #expect(tokens.map(\.range) == [
            UTF16Range(location: 0, length: 1),
            UTF16Range(location: 1, length: 1),
            UTF16Range(location: 2, length: 2),
            UTF16Range(location: 4, length: 1),
            UTF16Range(location: 5, length: 1),
        ])
        #expect(tokens[2].kind == .punctuation)
    }

    @Test func empty_text_has_no_tokens() {
        #expect(WordTokenizer.tokens("").isEmpty)
    }
}
