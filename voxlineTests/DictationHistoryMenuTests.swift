import Testing
import Foundation
@testable import voxline

@Suite struct DictationHistoryMenuTests {

    @Test func previewText_collapsesNewlines() {
        let s = "Hello\nthere\tworld"
        #expect(DictationHistoryMenuFormatter.previewText(s, maxChars: 50) == "Hello there world")
    }

    @Test func previewText_collapsesRunsOfWhitespace() {
        let s = "Hello   \n\n  there"
        #expect(DictationHistoryMenuFormatter.previewText(s, maxChars: 50) == "Hello there")
    }

    @Test func previewText_trimsLeadingAndTrailing() {
        let s = "   hello world   "
        #expect(DictationHistoryMenuFormatter.previewText(s, maxChars: 50) == "hello world")
    }

    @Test func previewText_truncatesWithEllipsis() {
        let s = String(repeating: "x", count: 60)
        let out = DictationHistoryMenuFormatter.previewText(s, maxChars: 10)
        #expect(out == "xxxxxxxxxx…")
    }

    @Test func previewText_doesNotTruncateUnderLimit() {
        let s = "short text"
        #expect(DictationHistoryMenuFormatter.previewText(s, maxChars: 50) == "short text")
    }

    @Test func rowLabel_combinesPreviewAndTimestamp() {
        let item = DictationHistoryItem(
            id: UUID(),
            timestamp: Date(timeIntervalSinceNow: -120),
            cleanedText: "Hey team."
        )
        let label = DictationHistoryMenuFormatter.rowLabel(for: item, now: Date())
        // Don't assert exact phrasing — RelativeDateTimeFormatter is locale-dependent —
        // but the preview and a separator must be present.
        #expect(label.hasPrefix("Hey team. · "))
    }
}
