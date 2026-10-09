import Testing
import Foundation
import CoreGraphics
@testable import voxline

@Suite struct PillLayoutTests {

    // MARK: - size

    @Test func size_with_text_is_wide_and_tall() {
        #expect(PillLayout.size(showsText: true, toastWidth: nil) == CGSize(width: 440, height: 64))
        #expect(PillLayout.size(showsText: true, toastWidth: 80) == CGSize(width: 440, height: 64))
    }

    @Test func size_for_toast_fits_text_within_bounds() {
        #expect(PillLayout.size(showsText: false, toastWidth: 200) == CGSize(width: 224, height: 32))
        #expect(PillLayout.size(showsText: false, toastWidth: 20) == CGSize(width: 120, height: 32))
        #expect(PillLayout.size(showsText: false, toastWidth: 900) == CGSize(width: 440, height: 32))
    }

    @Test func size_without_text_or_toast_is_compact() {
        #expect(PillLayout.size(showsText: false, toastWidth: nil) == CGSize(width: 160, height: 32))
    }

    // MARK: - origin

    @Test func origin_centers_horizontally_above_bottom_edge() {
        let origin = PillLayout.origin(
            for: CGSize(width: 440, height: 64),
            in: CGRect(x: 0, y: 0, width: 1000, height: 800)
        )
        #expect(origin == CGPoint(x: 280, y: 24))
    }

    @Test func origin_respects_offset_visible_frame() {
        let origin = PillLayout.origin(
            for: CGSize(width: 160, height: 32),
            in: CGRect(x: -1440, y: 70, width: 1440, height: 830)
        )
        #expect(origin == CGPoint(x: -800, y: 94))
    }

    @Test func origin_in_narrow_frame_pins_to_leading_inset() {
        let origin = PillLayout.origin(
            for: CGSize(width: 440, height: 64),
            in: CGRect(x: 100, y: 0, width: 300, height: 800)
        )
        #expect(origin == CGPoint(x: 108, y: 24))
    }

    @Test func origin_in_frame_just_wide_enough_stays_inside_insets() {
        let origin = PillLayout.origin(
            for: CGSize(width: 440, height: 64),
            in: CGRect(x: 0, y: 0, width: 456, height: 800)
        )
        #expect(origin == CGPoint(x: 8, y: 24))
    }

    // MARK: - elapsedLabel

    @Test func elapsed_under_a_minute_shows_tenths() {
        #expect(PillLayout.elapsedLabel(5.25) == String(format: "%.1fs", 5.25))
        #expect(PillLayout.elapsedLabel(0) == "0.0s")
        #expect(PillLayout.elapsedLabel(59.9) == "59.9s")
    }

    @Test func elapsed_past_a_minute_shows_minutes_and_seconds() {
        #expect(PillLayout.elapsedLabel(60) == "1:00")
        #expect(PillLayout.elapsedLabel(75) == "1:15")
        #expect(PillLayout.elapsedLabel(600) == "10:00")
    }

    // MARK: - content precedence

    @Test func recording_wins_over_toast() {
        #expect(PillLayout.content(status: .recording, hasToast: true) == .recording)
        #expect(PillLayout.content(status: .recording, hasToast: false) == .recording)
    }

    @Test func toast_wins_while_thinking() {
        #expect(PillLayout.content(status: .thinking, hasToast: true) == .toast)
        #expect(PillLayout.content(status: .thinking, hasToast: false) == .thinking)
    }

    @Test func toast_shows_outside_recording_and_thinking() {
        #expect(PillLayout.content(status: .idle, hasToast: true) == .toast)
        #expect(PillLayout.content(status: .error("boom"), hasToast: true) == .toast)
    }

    @Test(arguments: [
        AppStatus.idle,
        .error("boom"),
        .permissionsError("nope"),
        .preparingModel,
        .downloadingModel(progress: 0.5),
    ])
    func hidden_without_toast_outside_recording_and_thinking(status: AppStatus) {
        #expect(PillLayout.content(status: status, hasToast: false) == .hidden)
    }

    @Test func text_shows_only_for_recording_and_thinking_with_a_transcript() {
        #expect(PillLayout.showsText(content: .recording, hasText: true))
        #expect(PillLayout.showsText(content: .thinking, hasText: true))
        #expect(!PillLayout.showsText(content: .recording, hasText: false))
        #expect(!PillLayout.showsText(content: .thinking, hasText: false))
        #expect(!PillLayout.showsText(content: .toast, hasText: true))
        #expect(!PillLayout.showsText(content: .hidden, hasText: true))
    }

    // MARK: - transcript segments

    @Test(arguments: [
        ("Hello,", "world", "Hello,", " world"),
        ("Hello ", " world", "Hello", " world"),
        ("", "world", "", "world"),
        ("Hello", "", "Hello", ""),
    ])
    func segments_split_stable_and_volatile_with_join_seam(
        stable: String, volatile: String, primary: String, secondary: String
    ) {
        let partial = TranscriptPartial(stable: stable, volatile: volatile)
        let segments = PillLayout.transcriptSegments(partial)
        #expect(segments.primary == primary)
        #expect(segments.secondary == secondary)
        #expect(segments.primary + segments.secondary == partial.text)
    }
}
