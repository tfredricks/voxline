import Testing
@testable import voxline

@Suite struct LearnedStyleFormatterTests {

    @Test func note_only() {
        let style = LearnedStyle(categoryName: "Chat", note: "- Drops final periods.", examples: [])
        #expect(LearnedStyleFormatter.paragraph(style) == """
        Learned style for Chat (from this user's own past messages; follow it where it doesn't conflict with the rules above):
        - Drops final periods.
        """)
    }

    @Test func examples_only_are_quoted_and_escaped() {
        let style = LearnedStyle(categoryName: "Chat", note: nil, examples: ["Sounds good", #"Say "hi" \ wave"#])
        #expect(LearnedStyleFormatter.paragraph(style) == #"""
        Examples of this user's own writing in this app. Match their voice; never copy their content:
        - "Sounds good"
        - "Say \"hi\" \\ wave"
        """#)
    }

    @Test func note_and_examples_are_separate_blocks() throws {
        let style = LearnedStyle(categoryName: "Email", note: "- Signs off with Best.", examples: ["Thanks for the update"])
        let paragraph = try #require(LearnedStyleFormatter.paragraph(style))
        #expect(paragraph == LearnedStyleFormatter.noteHeader(categoryName: "Email") + "\n- Signs off with Best.\n\n"
                + LearnedStyleFormatter.examplesHeader + "\n- \"Thanks for the update\"")
    }

    @Test func nothing_to_say_is_nil() {
        #expect(LearnedStyleFormatter.paragraph(LearnedStyle(categoryName: "Chat", note: nil, examples: [])) == nil)
        #expect(LearnedStyleFormatter.paragraph(LearnedStyle(categoryName: "Chat", note: "  \n", examples: [])) == nil)
    }

    @Test func long_examples_are_clipped_at_a_word() {
        let words = Array(repeating: "word", count: 100).joined(separator: " ")
        let clipped = LearnedStyleFormatter.clip(words)
        #expect(clipped.hasSuffix("word…"))
        #expect(clipped.count <= LearnedStyleFormatter.exampleLimit + 1)
        #expect(LearnedStyleFormatter.clip("short") == "short")
        #expect(LearnedStyleFormatter.clip(String(repeating: "a", count: 450)) == String(repeating: "a", count: 400) + "…")
    }
}
