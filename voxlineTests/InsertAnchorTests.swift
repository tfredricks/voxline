import Testing
@testable import voxline

@Suite struct InsertAnchorTests {

    private func caret(_ at: Int) -> UTF16Range { UTF16Range(location: at, length: 0) }

    @Test func finds_the_text_ending_at_the_caret() throws {
        let value = "Hi there. ask Cooper Nettis to review. Bye"
        let inserted = "ask Cooper Nettis to review."
        let anchor = try #require(AnchorText.make(value: value, caret: caret(38), inserted: inserted))
        #expect(anchor.range == UTF16Range(location: 10, length: 28))
        #expect(anchor.prefix == "Hi there. ")
        #expect(anchor.suffix == " Bye")
        #expect(anchor.inserted == inserted)
    }

    @Test func refuses_a_caret_not_right_after_the_text() {
        #expect(AnchorText.make(value: "Hi there. ask", caret: caret(5), inserted: "ask") == nil)
    }

    @Test func refuses_a_selection() {
        #expect(AnchorText.make(value: "ask", caret: UTF16Range(location: 3, length: 1), inserted: "ask") == nil)
        #expect(AnchorText.make(value: "ask", caret: UTF16Range(location: 0, length: 3), inserted: "ask") == nil)
    }

    @Test func refuses_a_caret_outside_the_value_or_empty_text() {
        #expect(AnchorText.make(value: "ask", caret: caret(9), inserted: "ask") == nil)
        #expect(AnchorText.make(value: "ask", caret: caret(3), inserted: "") == nil)
    }

    @Test func context_is_capped_at_32_units() throws {
        let value = String(repeating: "a", count: 50) + "XYZ" + String(repeating: "b", count: 50)
        let anchor = try #require(AnchorText.make(value: value, caret: caret(53), inserted: "XYZ"))
        #expect(anchor.prefix == String(repeating: "a", count: 32))
        #expect(anchor.suffix == String(repeating: "b", count: 32))
    }

    @Test func context_snaps_outward_around_emoji_and_crlf() throws {
        let emojiBefore = "👍" + String(repeating: "a", count: 31) + "XYZ"
        let before = try #require(AnchorText.make(value: emojiBefore, caret: caret(36), inserted: "XYZ"))
        #expect(before.prefix == "👍" + String(repeating: "a", count: 31))

        let emojiAfter = "XYZ" + String(repeating: "b", count: 31) + "👍"
        let after = try #require(AnchorText.make(value: emojiAfter, caret: caret(3), inserted: "XYZ"))
        #expect(after.suffix == String(repeating: "b", count: 31) + "👍")

        let crlf = "\r\n" + String(repeating: "a", count: 31) + "XYZ"
        let lines = try #require(AnchorText.make(value: crlf, caret: caret(36), inserted: "XYZ"))
        #expect(lines.prefix.hasPrefix("\r\n"))
    }

    @Test func field_edges_give_empty_context() throws {
        let anchor = try #require(AnchorText.make(value: "XYZ tail", caret: caret(3), inserted: "XYZ"))
        #expect(anchor.prefix == "")
        #expect(anchor.suffix == " tail")
        let whole = try #require(AnchorText.make(value: "XYZ", caret: caret(3), inserted: "XYZ"))
        #expect(whole.prefix == "" && whole.suffix == "")
    }
}
