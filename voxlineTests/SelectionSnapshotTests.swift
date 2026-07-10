import Testing
import Foundation
@testable import voxline

@Suite struct SelectionSnapshotTests {
    @Test func cap_returns_short_strings_unchanged() {
        #expect(DefaultSelectionSnapshot.cap("hello") == "hello")
    }

    @Test func cap_truncates_to_selectionMax() {
        let long = String(repeating: "a", count: DefaultSelectionSnapshot.selectionMax + 500)
        let capped = DefaultSelectionSnapshot.cap(long)
        #expect(capped.count == DefaultSelectionSnapshot.selectionMax)
    }

    @Test func cap_keeps_exactly_max_length() {
        let exact = String(repeating: "b", count: DefaultSelectionSnapshot.selectionMax)
        #expect(DefaultSelectionSnapshot.cap(exact) == exact)
    }
}
