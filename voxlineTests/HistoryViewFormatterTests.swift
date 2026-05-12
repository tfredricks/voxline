import Testing
@testable import voxline

@Suite struct HistoryViewFormatterTests {

    @Test func preview_returns_short_text_unchanged() {
        #expect(HistoryViewFormatter.previewText("hello", maxChars: 80) == "hello")
    }

    @Test func preview_collapses_whitespace_runs_into_single_spaces() {
        #expect(HistoryViewFormatter.previewText("a\n\nb\tc   d", maxChars: 80) == "a b c d")
    }

    @Test func preview_truncates_with_ellipsis() {
        let long = String(repeating: "x", count: 100)
        let out = HistoryViewFormatter.previewText(long, maxChars: 10)
        #expect(out == String(repeating: "x", count: 10) + "…")
    }

    @Test func preview_trims_surrounding_whitespace() {
        #expect(HistoryViewFormatter.previewText("   hello world   ", maxChars: 80) == "hello world")
    }

    @Test func preview_empty_string_returns_empty() {
        #expect(HistoryViewFormatter.previewText("", maxChars: 80) == "")
    }
}
