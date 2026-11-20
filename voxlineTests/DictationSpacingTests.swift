import Testing
@testable import voxline

@Suite struct DictationSpacingTests {

    private func spaced(_ text: String, before: String?, bundleID: String? = "com.apple.Notes") -> String {
        DictationSpacing.spaced(text, before: before, bundleID: bundleID)
    }

    @Test func separates_back_to_back_dictations() {
        #expect(spaced("How are you?", before: "Hello.") == " How are you?")
        #expect(spaced("world", before: "hello") == " world")
    }

    @Test func leaves_text_alone_after_whitespace_or_at_field_start() {
        #expect(spaced("How", before: "Hello. ") == "How")
        #expect(spaced("Next", before: "Line one\n") == "Next")
        #expect(spaced("First", before: nil) == "First")
    }

    @Test func no_space_after_openers_or_before_closers() {
        #expect(spaced("note", before: "see (") == "note")
        #expect(spaced("quoted", before: "he said \"") == "quoted")
        #expect(spaced(", and more", before: "this") == ", and more")
        #expect(spaced(".", before: "end") == ".")
    }

    @Test func unspaced_scripts_stay_unspaced() {
        #expect(spaced("世界", before: "你好") == "世界")
        #expect(spaced("次です", before: "です。") == "次です")
    }

    @Test func terminals_are_left_alone() {
        #expect(spaced("ls", before: "user@host %", bundleID: "com.apple.Terminal") == "ls")
    }
}
