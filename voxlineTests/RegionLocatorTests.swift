import Foundation
import Testing
@testable import voxline

@Suite struct RegionLocatorTests {

    /// Anchors `inserted` where it first appears in `value`, caret right after it.
    private func anchor(_ value: String, _ inserted: String) throws -> AnchorText {
        let found = (value as NSString).range(of: inserted)
        return try #require(AnchorText.make(
            value: value, caret: UTF16Range(location: found.location + found.length, length: 0), inserted: inserted
        ))
    }

    private let inserted = "ask Cooper Nettis to review."
    private let original = "Hi Bob, ask Cooper Nettis to review. Thanks"

    @Test func unchanged() throws {
        #expect(RegionLocator.locate(try anchor(original, inserted), in: original) == .unchanged)
    }

    @Test func a_word_edited_inside() throws {
        let match = RegionLocator.locate(try anchor(original, inserted), in: "Hi Bob, ask Kubernetes to review. Thanks")
        #expect(match == .changed("ask Kubernetes to review."))
    }

    @Test func text_typed_before_the_prefix_and_after_the_suffix() throws {
        let match = RegionLocator.locate(try anchor(original, inserted), in: "Note: Hi Bob, ask Kubernetes to review. Thanks!!")
        #expect(match == .changed("ask Kubernetes to review."))
    }

    @Test func a_repeated_prefix_is_ambiguous() throws {
        let match = RegionLocator.locate(try anchor(original, inserted), in: "Hi Bob, Hi Bob, ask Kubernetes to review. Thanks")
        #expect(match == .ambiguous)
    }

    @Test func an_edited_prefix_or_missing_suffix_is_ambiguous() throws {
        let a = try anchor(original, inserted)
        #expect(RegionLocator.locate(a, in: "Hi Rob, ask Kubernetes to review. Thanks") == .ambiguous)
        #expect(RegionLocator.locate(a, in: "Hi Bob, ask Kubernetes to review. Cheers") == .ambiguous)
    }

    @Test func empty_context_spans_the_whole_value() throws {
        let a = try anchor("ask Cooper Nettis", "ask Cooper Nettis")
        #expect(RegionLocator.locate(a, in: "ask Kubernetes") == .changed("ask Kubernetes"))
        #expect(RegionLocator.locate(a, in: "") == .discarded)
    }

    @Test func an_implausibly_long_region_is_ambiguous() throws {
        let a = try anchor("short text", "short text")
        #expect(RegionLocator.locate(a, in: String(repeating: "x", count: 300)) == .ambiguous)
        #expect(RegionLocator.locate(a, in: String(repeating: "x", count: 210)) != .ambiguous)
    }

    @Test func under_a_quarter_is_discarded() throws {
        let match = RegionLocator.locate(try anchor(original, inserted), in: "Hi Bob, ask Thanks")
        #expect(match == .discarded)
    }

    @Test func offsets_are_utf16_around_emoji() throws {
        let a = try anchor("👋 Hi, ask Cooper Nettis", "ask Cooper Nettis")
        #expect(RegionLocator.locate(a, in: "👋 Hi, ask Kubernetes") == .changed("ask Kubernetes"))
    }

    @Test func log_names_carry_no_text() {
        #expect(RegionMatch.changed("secret").logName == "changed")
        #expect(RegionMatch.unreadable.logName == "unreadable")
    }
}
