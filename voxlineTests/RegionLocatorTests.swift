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
    /// Both sides are longer than the context length, so neither is clipped.
    private let before = "Please check the quarterly figures before Friday. Hi Bob, "
    private let after = " Thanks for reading the figures, really appreciated."
    private var original: String { before + inserted + after }

    @Test func unchanged() throws {
        #expect(RegionLocator.locate(try anchor(original, inserted), in: original) == .unchanged)
    }

    @Test func a_word_edited_inside() throws {
        let match = RegionLocator.locate(try anchor(original, inserted), in: before + "ask Kubernetes to review." + after)
        #expect(match == .changed("ask Kubernetes to review."))
    }

    @Test func text_typed_before_the_prefix_and_after_the_suffix() throws {
        let match = RegionLocator.locate(
            try anchor(original, inserted), in: "Note: " + before + "ask Kubernetes to review." + after + "!!"
        )
        #expect(match == .changed("ask Kubernetes to review."))
    }

    @Test func a_repeated_prefix_is_ambiguous() throws {
        let match = RegionLocator.locate(
            try anchor(original, inserted), in: before + before + "ask Kubernetes to review." + after
        )
        #expect(match == .ambiguous)
    }

    @Test func an_edited_prefix_or_missing_suffix_is_ambiguous() throws {
        let a = try anchor(original, inserted)
        #expect(RegionLocator.locate(a, in: before.replacingOccurrences(of: "Bob", with: "Rob") + "ask Kubernetes to review." + after) == .ambiguous)
        #expect(RegionLocator.locate(a, in: before + "ask Kubernetes to review. Cheers.") == .ambiguous)
    }

    @Test func a_full_length_suffix_occurring_twice_after_the_region_start_is_ambiguous() throws {
        let a = try anchor(original, inserted)
        #expect(RegionLocator.locate(a, in: before + "ask Kubernetes to review." + after + after) == .ambiguous)
    }

    @Test func short_suffix_matches_only_at_the_end_of_the_value() throws {
        let value = "Hi Bob, ask Cooper Nettis to review. "
        let a = try anchor(value, inserted)
        #expect(a.suffix == " ")
        #expect(RegionLocator.locate(a, in: value) == .unchanged)
        #expect(RegionLocator.locate(a, in: "Hi Bob, ask Kubernetes to review. ") == .changed("ask Kubernetes to review."))
        #expect(RegionLocator.locate(a, in: "Hi Bob, ask Kubernetes to review. Cheers") == .ambiguous)
    }

    @Test func short_prefix_at_the_field_start_locates_the_region() throws {
        let a = try anchor("Hi Bob, ask Cooper Nettis to review. Thanks", inserted)
        #expect(a.prefix == "Hi Bob, ")
        #expect(RegionLocator.locate(a, in: "Hi Bob, ask Kubernetes to review. Thanks") == .changed("ask Kubernetes to review."))
        #expect(RegionLocator.locate(a, in: "Note: Hi Bob, ask Kubernetes to review. Thanks") == .ambiguous)
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
        let match = RegionLocator.locate(try anchor(original, inserted), in: before + "ask" + after)
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
