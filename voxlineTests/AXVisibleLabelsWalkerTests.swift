import Testing
import Foundation
@testable import voxline

@Suite struct AXVisibleLabelsWalkerTests {

    private let walker = DefaultAXVisibleLabelsWalker()

    @Test func normalize_trims_leading_and_trailing_whitespace() {
        #expect(walker.normalize("  Kamil  ") == "Kamil")
        #expect(walker.normalize("\nQ4 Renewal\n") == "Q4 Renewal")
    }

    @Test func normalize_returns_nil_for_empty_or_whitespace_only() {
        #expect(walker.normalize("") == nil)
        #expect(walker.normalize("   ") == nil)
        #expect(walker.normalize("\n\t  ") == nil)
    }

    @Test func normalize_drops_strings_over_the_per_label_char_cap() {
        let long = String(repeating: "x", count: DefaultAXVisibleLabelsWalker.maxLabelChars + 1)
        #expect(walker.normalize(long) == nil)
        let exact = String(repeating: "x", count: DefaultAXVisibleLabelsWalker.maxLabelChars)
        #expect(walker.normalize(exact) == exact)
    }

    @Test func normalize_drops_pure_punctuation_or_symbols() {
        #expect(walker.normalize("…") == nil)
        #expect(walker.normalize("—") == nil)
        #expect(walker.normalize("• • •") == nil)
    }

    @Test func normalize_keeps_non_latin_alphanumerics() {
        // CharacterSet.alphanumerics is Unicode-wide.
        #expect(walker.normalize("こんにちは") == "こんにちは")
        #expect(walker.normalize("北京") == "北京")
        #expect(walker.normalize("Παράδειγμα") == "Παράδειγμα")
    }

    @Test func normalize_accepts_alphanumeric_mixed_with_punctuation() {
        #expect(walker.normalize("Q4 — Renewal") == "Q4 — Renewal")
        #expect(walker.normalize("#sales-pipeline") == "#sales-pipeline")
    }
}
