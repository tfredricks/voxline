import Testing
@testable import voxline

@Suite struct AXSelectionReaderTests {

    final class RecordingFallback: SelectionSnapshotting, @unchecked Sendable {
        var result: String?
        private(set) var calls = 0
        init(result: String?) { self.result = result }
        func readSelection() async -> String? { calls += 1; return result }
    }

    @Test func uses_ax_selection_when_present_and_skips_fallback() async {
        let fallback = RecordingFallback(result: "from clipboard")
        let reader = AXSelectionReader(readAX: { "from ax" }, fallback: fallback)
        #expect(await reader.readSelection() == "from ax")
        #expect(fallback.calls == 0)
    }

    @Test func falls_back_when_ax_returns_nil() async {
        let fallback = RecordingFallback(result: "from clipboard")
        let reader = AXSelectionReader(readAX: { nil }, fallback: fallback)
        #expect(await reader.readSelection() == "from clipboard")
        #expect(fallback.calls == 1)
    }

    @Test func falls_back_when_ax_returns_empty() async {
        let fallback = RecordingFallback(result: nil)
        let reader = AXSelectionReader(readAX: { "" }, fallback: fallback)
        #expect(await reader.readSelection() == nil)
        #expect(fallback.calls == 1)
    }
}
