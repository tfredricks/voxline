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

    @Test func retry_shows_for_an_error_while_offered() {
        #expect(PillLayout.content(status: .error("boom"), hasToast: false, retryOffered: true) == .retry)
        #expect(PillLayout.content(status: .error("boom"), hasToast: false, retryOffered: false) == .hidden)
    }

    @Test func toast_wins_over_retry() {
        #expect(PillLayout.content(status: .error("boom"), hasToast: true, retryOffered: true) == .toast)
    }

    @Test(arguments: [
        (AppStatus.idle, PillContent.hidden),
        (.permissionsError("nope"), .hidden),
        (.recording, .recording),
        (.thinking, .thinking),
        (.preparingModel, .hidden),
    ])
    func retry_needs_an_error_status(status: AppStatus, expected: PillContent) {
        #expect(PillLayout.content(status: status, hasToast: false, retryOffered: true) == expected)
    }

    @Test func retry_is_offered_only_for_an_error_with_a_transcript() {
        #expect(PillLayout.offersRetry(status: .error("boom"), hasRetryTranscript: true))
        #expect(!PillLayout.offersRetry(status: .error("boom"), hasRetryTranscript: false))
        #expect(!PillLayout.offersRetry(status: .permissionsError("nope"), hasRetryTranscript: true))
        #expect(!PillLayout.offersRetry(status: .idle, hasRetryTranscript: true))
    }

    @Test func retry_never_shows_transcript_text() {
        #expect(!PillLayout.showsText(content: .retry, hasText: true))
    }

    @Test(arguments: [
        ("Couldn't reach Anthropic. Raw transcript copied to the clipboard — paste to recover it.", "Couldn't reach Anthropic."),
        ("LLM cleanup failed: v1.2 timed out. Raw transcript copied.", "LLM cleanup failed: v1.2 timed out."),
        ("Text insertion failed.", "Text insertion failed."),
        ("No period here", "No period here"),
        ("", ""),
    ])
    func first_sentence_ends_at_the_first_period_space(message: String, expected: String) {
        #expect(PillLayout.firstSentence(message) == expected)
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

    @Test func the_pill_takes_clicks_for_retry_and_for_a_toast_with_an_action() {
        #expect(PillLayout.acceptsClicks(content: .retry, hasToastAction: false))
        #expect(PillLayout.acceptsClicks(content: .toast, hasToastAction: true))
        #expect(!PillLayout.acceptsClicks(content: .toast, hasToastAction: false))
        #expect(!PillLayout.acceptsClicks(content: .recording, hasToastAction: true))
        #expect(!PillLayout.acceptsClicks(content: .hidden, hasToastAction: true))
    }

    @Test func a_button_adds_its_width_and_spacing() {
        #expect(PillLayout.messageWidth(textWidth: 100, hasButton: false) == 100)
        #expect(PillLayout.messageWidth(textWidth: 100, hasButton: true) == 100 + PillLayout.retrySpacing + PillLayout.retryButtonWidth)
    }
}
