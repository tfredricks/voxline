import Testing
import Foundation
import CoreGraphics
@testable import voxline

@Suite struct MeetingTimerLayoutTests {

    // MARK: - label

    @Test func label_under_an_hour_is_minutes_and_seconds() {
        #expect(MeetingTimerLayout.label(elapsed: 0) == "0:00")
        #expect(MeetingTimerLayout.label(elapsed: 5.9) == "0:05")
        #expect(MeetingTimerLayout.label(elapsed: 754) == "12:34")
        #expect(MeetingTimerLayout.label(elapsed: 3599) == "59:59")
    }

    @Test func label_past_an_hour_adds_hours() {
        #expect(MeetingTimerLayout.label(elapsed: 3600) == "1:00:00")
        #expect(MeetingTimerLayout.label(elapsed: 5025) == "1:23:45")
        #expect(MeetingTimerLayout.label(elapsed: 39605) == "11:00:05")
    }

    @Test func label_clamps_negative_elapsed_to_zero() {
        #expect(MeetingTimerLayout.label(elapsed: -3) == "0:00")
    }

    @Test func widest_label_is_at_least_as_long_as_any_label_under_ten_hours() {
        let widest = MeetingTimerLayout.widestLabel
        for elapsed in [0.0, 754, 3599, 3600, 35999] {
            #expect(MeetingTimerLayout.label(elapsed: elapsed).count <= widest.count)
        }
    }

    // MARK: - frame

    private let screen = CGRect(x: 0, y: 25, width: 1440, height: 850)

    @Test func frame_without_saved_position_sits_in_top_right_corner() {
        let frame = MeetingTimerLayout.frame(
            size: CGSize(width: 110, height: 28), saved: nil, visibleFrame: screen
        )
        #expect(frame == CGRect(x: 1440 - 110 - 16, y: 25 + 850 - 28 - 8, width: 110, height: 28))
    }

    @Test func frame_keeps_saved_origin_and_takes_new_size() {
        let frame = MeetingTimerLayout.frame(
            size: CGSize(width: 110, height: 28),
            saved: CGRect(x: 400, y: 300, width: 96, height: 28),
            visibleFrame: screen
        )
        #expect(frame == CGRect(x: 400, y: 300, width: 110, height: 28))
    }

    @Test func frame_shifts_a_widened_chip_back_inside_the_right_edge() {
        let frame = MeetingTimerLayout.frame(
            size: CGSize(width: 110, height: 28),
            saved: CGRect(x: 1440 - 96, y: 300, width: 96, height: 28),
            visibleFrame: screen
        )
        #expect(frame == CGRect(x: 1440 - 110, y: 300, width: 110, height: 28))
    }

    @Test func frame_clamps_a_saved_position_from_a_missing_display() {
        let frame = MeetingTimerLayout.frame(
            size: CGSize(width: 110, height: 28),
            saved: CGRect(x: -900, y: 2000, width: 96, height: 28),
            visibleFrame: screen
        )
        #expect(frame == CGRect(x: 0, y: 25 + 850 - 28, width: 110, height: 28))
    }

    // MARK: - resized

    @Test func resized_keeps_the_top_left_corner_and_grows_downward() {
        let chip = CGRect(x: 400, y: 600, width: 110, height: 28)
        let frame = MeetingTimerLayout.resized(chip, to: CGSize(width: 360, height: 178), visibleFrame: screen)
        #expect(frame == CGRect(x: 400, y: 600 + 28 - 178, width: 360, height: 178))
    }

    @Test func resized_back_to_the_chip_returns_the_corner() {
        let chip = CGRect(x: 400, y: 600, width: 110, height: 28)
        let expanded = MeetingTimerLayout.resized(chip, to: CGSize(width: 360, height: 178), visibleFrame: screen)
        let collapsed = MeetingTimerLayout.resized(expanded, to: CGSize(width: 110, height: 28), visibleFrame: screen)
        #expect(collapsed == chip)
    }

    @Test func resized_clamps_at_the_bottom_and_right_edges() {
        let chip = CGRect(x: 1440 - 110 - 16, y: 25 + 40, width: 110, height: 28)
        let frame = MeetingTimerLayout.resized(chip, to: CGSize(width: 360, height: 178), visibleFrame: screen)
        #expect(frame == CGRect(x: 1440 - 360, y: 25, width: 360, height: 178))
    }

    @Test func body_size_is_the_spec_size() {
        #expect(MeetingTimerLayout.bodySize == CGSize(width: 360, height: 150))
    }
}
