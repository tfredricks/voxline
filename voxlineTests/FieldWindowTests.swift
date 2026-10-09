import Foundation
import Testing
@testable import voxline

@Suite struct FieldWindowTests {

    private func text(_ unit: String, count: Int) -> NSString {
        String(repeating: unit, count: count) as NSString
    }

    private func caret(_ location: Int) -> UTF16Range { UTF16Range(location: location, length: 0) }

    @Test func default_budget_is_twelve_thousand_units() {
        #expect(FieldWindow.budget == 12_000)
    }

    @Test func whole_field_when_it_fits() {
        let window = FieldWindow.make(text: text("a", count: 100), anchor: caret(50), budget: 12_000)
        #expect(window == UTF16Range(location: 0, length: 100))
    }

    @Test func whole_field_when_it_exactly_fills_the_budget() {
        let window = FieldWindow.make(text: text("a", count: 12_000), anchor: caret(6_000))
        #expect(window == UTF16Range(location: 0, length: 12_000))
    }

    @Test func empty_field_is_an_empty_window() {
        #expect(FieldWindow.make(text: "", anchor: caret(0)) == UTF16Range(location: 0, length: 0))
    }

    @Test func caret_in_the_middle_splits_two_to_one() {
        let window = FieldWindow.make(text: text("a", count: 30_000), anchor: caret(15_000), budget: 12_000)
        #expect(window == UTF16Range(location: 7_000, length: 12_000))
    }

    @Test func caret_near_the_start_donates_room_to_after() {
        let window = FieldWindow.make(text: text("a", count: 30_000), anchor: caret(2_000), budget: 12_000)
        #expect(window == UTF16Range(location: 0, length: 12_000))
    }

    @Test func caret_near_the_end_donates_room_to_before() {
        let window = FieldWindow.make(text: text("a", count: 30_000), anchor: caret(29_000), budget: 12_000)
        #expect(window == UTF16Range(location: 18_000, length: 12_000))
    }

    @Test func selection_splits_the_remaining_budget() {
        let window = FieldWindow.make(
            text: text("a", count: 30_000),
            anchor: UTF16Range(location: 10_000, length: 4_000),
            budget: 12_000
        )
        #expect(window == UTF16Range(location: 4_667, length: 12_000))
    }

    @Test func end_edge_snaps_inward_out_of_a_surrogate_pair() {
        let emoji = text("😀", count: 15_000)
        #expect(emoji.length == 30_000)
        let window = FieldWindow.make(text: emoji, anchor: caret(15_000), budget: 12_001)
        #expect(window == UTF16Range(location: 7_000, length: 12_000))
    }

    @Test func start_edge_snaps_inward_out_of_a_surrogate_pair() {
        let window = FieldWindow.make(text: text("😀", count: 15_000), anchor: caret(15_000), budget: 12_005)
        #expect(window == UTF16Range(location: 6_998, length: 12_004))
    }

    @Test func both_edges_snap_inward() {
        let window = FieldWindow.make(text: text("😀", count: 15_000), anchor: caret(15_000), budget: 12_002)
        #expect(window == UTF16Range(location: 7_000, length: 12_000))
    }

    @Test func snapped_window_never_splits_a_composed_character() {
        let emoji = text("😀", count: 15_000)
        for budget in 12_000...12_007 {
            let window = FieldWindow.make(text: emoji, anchor: caret(15_000), budget: budget)
            #expect(window.location % 2 == 0)
            #expect(window.end % 2 == 0)
            #expect(window.length <= budget)
        }
    }

    @Test func end_edge_snaps_inward_out_of_a_crlf() {
        let window = FieldWindow.make(text: text("\r\n", count: 15_000), anchor: caret(15_000), budget: 12_001)
        #expect(window == UTF16Range(location: 7_000, length: 12_000))
    }

    @Test func start_edge_snaps_inward_out_of_a_crlf() {
        let window = FieldWindow.make(text: text("\r\n", count: 15_000), anchor: caret(15_000), budget: 12_005)
        #expect(window == UTF16Range(location: 6_998, length: 12_004))
    }

    @Test func crlf_is_never_split_at_either_edge() {
        let lines = text("\r\n", count: 15_000)
        for budget in 12_000...12_007 {
            let window = FieldWindow.make(text: lines, anchor: caret(15_000), budget: budget)
            #expect(window.location % 2 == 0)
            #expect(window.end % 2 == 0)
            #expect(window.length <= budget)
        }
    }

    @Test func combining_marks_stay_with_their_base() {
        let decomposed = text("e\u{301}", count: 15_000)
        #expect(decomposed.length == 30_000)
        let window = FieldWindow.make(text: decomposed, anchor: caret(15_000), budget: 12_002)
        #expect(window == UTF16Range(location: 7_000, length: 12_000))
    }

    @Test func anchor_longer_than_the_budget_is_returned_as_is() {
        let anchor = UTF16Range(location: 5_000, length: 13_000)
        let window = FieldWindow.make(text: text("a", count: 30_000), anchor: anchor, budget: 12_000)
        #expect(window == anchor)
    }

    @Test func snapping_never_cuts_into_the_anchor() {
        let anchor = UTF16Range(location: 15_001, length: 11_999)
        let window = FieldWindow.make(text: text("😀", count: 15_000), anchor: anchor, budget: 12_000)
        #expect(window == anchor)
    }

    @Test func end_clamp_keeps_an_anchor_that_ends_inside_a_surrogate_pair() {
        let emoji = text("😀", count: 15_000)
        for (anchor, budget) in [
            (UTF16Range(location: 15_000, length: 1), 1),
            (UTF16Range(location: 15_000, length: 12_001), 12_000),
        ] {
            let window = FieldWindow.make(text: emoji, anchor: anchor, budget: budget)
            #expect(window == anchor)
            #expect(window.location <= anchor.location && window.end >= anchor.end)
        }
    }

    private static let family = "👨\u{200D}👩\u{200D}👧"

    @Test func zwj_family_is_eight_units() {
        #expect((Self.family as NSString).length == 8)
    }

    @Test func both_edges_snap_out_of_a_zwj_sequence() {
        let families = text(Self.family, count: 4_000)
        let window = FieldWindow.make(text: families, anchor: caret(16_000), budget: 12_003)
        #expect(window == UTF16Range(location: 8_000, length: 12_000))
    }

    @Test func zwj_sequence_is_never_split_at_either_edge() {
        let families = text(Self.family, count: 4_000)
        for budget in 12_000...12_015 {
            let window = FieldWindow.make(text: families, anchor: caret(16_000), budget: budget)
            #expect(window.location % 8 == 0)
            #expect(window.end % 8 == 0)
            #expect(window.length <= budget)
            #expect(window.location <= 16_000 && window.end >= 16_000)
        }
    }
}
