import Foundation
import Testing
@testable import voxline

@Suite struct TextDiffTests {

    private func change(_ location: Int, _ length: Int, _ replacement: String) -> TextDiff.Change {
        TextDiff.Change(range: UTF16Range(location: location, length: length), replacement: replacement)
    }

    private func apply(_ change: TextDiff.Change, to old: String) -> String {
        (old as NSString).replacingCharacters(in: change.range.nsRange, with: change.replacement)
    }

    @Test func identical_strings_have_no_change() {
        #expect(TextDiff.minimalChange(from: "hello", to: "hello") == nil)
        #expect(TextDiff.minimalChange(from: "", to: "") == nil)
    }

    @Test func insert_at_start() {
        #expect(TextDiff.minimalChange(from: "world", to: "hello world") == change(0, 0, "hello "))
    }

    @Test func insert_in_middle() {
        #expect(TextDiff.minimalChange(from: "ab", to: "aXb") == change(1, 0, "X"))
    }

    @Test func insert_at_end() {
        #expect(TextDiff.minimalChange(from: "ab", to: "abc") == change(2, 0, "c"))
    }

    @Test func insert_into_empty() {
        #expect(TextDiff.minimalChange(from: "", to: "abc") == change(0, 0, "abc"))
    }

    @Test func delete_at_start() {
        #expect(TextDiff.minimalChange(from: "abc", to: "bc") == change(0, 1, ""))
    }

    @Test func delete_in_middle() {
        #expect(TextDiff.minimalChange(from: "abc", to: "ac") == change(1, 1, ""))
    }

    @Test func delete_at_end() {
        #expect(TextDiff.minimalChange(from: "abc", to: "ab") == change(2, 1, ""))
    }

    @Test func delete_everything() {
        #expect(TextDiff.minimalChange(from: "abc", to: "") == change(0, 3, ""))
    }

    @Test func replace_a_word() {
        #expect(TextDiff.minimalChange(from: "the cat sat", to: "the dog sat") == change(4, 3, "dog"))
    }

    @Test func repeated_characters_resolve_to_the_trailing_copy() {
        #expect(TextDiff.minimalChange(from: "aaa", to: "aa") == change(2, 1, ""))
    }

    @Test func surrogate_pair_is_never_split() throws {
        let result = try #require(TextDiff.minimalChange(from: "a😀b", to: "a😁b"))
        #expect(result == change(1, 2, "😁"))
        #expect(apply(result, to: "a😀b") == "a😁b")
    }

    @Test func combining_mark_widens_to_its_base() throws {
        let result = try #require(TextDiff.minimalChange(from: "cafe\u{301}", to: "cafe"))
        #expect(result == change(3, 2, "e"))
        #expect(apply(result, to: "cafe\u{301}") == "cafe")
    }

    @Test func crlf_is_never_split() throws {
        let result = try #require(TextDiff.minimalChange(from: "a\r\nb", to: "a\nb"))
        #expect(result == change(1, 2, "\n"))
        #expect(apply(result, to: "a\r\nb") == "a\nb")
    }

    @Test func crlf_is_never_split_from_the_front() throws {
        let result = try #require(TextDiff.minimalChange(from: "a\r\nb", to: "a\rb"))
        #expect(result == change(1, 2, "\r"))
        #expect(apply(result, to: "a\r\nb") == "a\rb")
    }

    @Test func ranges_are_utf16_units() throws {
        let result = try #require(TextDiff.minimalChange(from: "👍 one", to: "👍 two"))
        #expect(result == change(3, 3, "two"))
    }

    @Test func applying_the_change_always_yields_the_new_text() throws {
        let pairs: [(String, String)] = [
            ("the cat sat on the mat", "the cat sat on a mat"),
            ("first\nsecond\nthird", "first\nthird"),
            ("👨‍👩‍👧 family", "👨‍👩‍👦 family"),
            ("🇺🇸 flag", "🇫🇷 flag"),
            ("one\r\ntwo", "one\r\n\r\ntwo"),
            ("", "x"),
            ("x", ""),
            ("abab", "ab"),
        ]
        for (old, new) in pairs {
            let result = try #require(TextDiff.minimalChange(from: old, to: new))
            #expect(apply(result, to: old) == new)
        }
    }
}
