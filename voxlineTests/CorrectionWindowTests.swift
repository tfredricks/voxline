import ApplicationServices
import Foundation
import Testing
@testable import voxline

@Suite(.timeLimit(.minutes(1))) @MainActor struct CorrectionWindowTests {

    static let original = "ask Cooper Nettis to review"
    static let fixed = "ask Kubernetes to review"

    struct Harness {
        let window: CorrectionWindow
        let reader: FakeCorrectionReader
        let clock: ManualClock
        let ends: LockedBox<[WindowEnd]>
        let element: FakeAXTextElement
    }

    private func makeHarness(
        anchors: ((FakeAXTextElement) -> [AnchorRead])? = nil,
        focus: ((FakeAXTextElement) -> [AXRead<AXElementRef>])? = nil,
        values: [AXRead<String>] = [.value(Self.original)],
        anchorBlock: DispatchSemaphore? = nil
    ) -> Harness {
        let element = FakeAXTextElement()
        let reader = FakeCorrectionReader(
            anchors: anchors?(element) ?? [FakeCorrectionReader.anchored(element, value: Self.original, inserted: Self.original)],
            focus: focus?(element) ?? [.value(element.ref)],
            values: values,
            anchorBlock: anchorBlock
        )
        let clock = ManualClock()
        let ends = LockedBox<[WindowEnd]>([])
        let window = CorrectionWindow(
            reader: reader,
            sleep: { @MainActor in try await clock.sleep($0) },
            onEnd: { end in ends.mutate { $0.append(end) } }
        )
        return Harness(window: window, reader: reader, clock: clock, ends: ends, element: element)
    }

    /// Lets `count` one-second polls run; each starts only after the previous
    /// one finished and went back to sleep.
    private func runTicks(_ count: Int, _ h: Harness) async {
        for _ in 0..<count {
            #expect(await eventually { h.clock.pendingCount == 1 })
            let before = h.reader.focusCalls
            await h.clock.advance(by: CorrectionWindow.tick)
            #expect(await eventually { h.reader.focusCalls == before + 1 })
        }
    }

    private func result(_ h: Harness) async -> WindowResult? {
        #expect(await eventually { h.ends.read().count == 1 })
        guard case .finished(let result)? = h.ends.read().first else {
            Issue.record("expected a finished window, got \(h.ends.read())")
            return nil
        }
        return result
    }

    @Test func ends_after_thirty_polls_with_the_final_read() async throws {
        let h = makeHarness(values: [.value(Self.fixed)])
        h.window.start(inserted: Self.original)
        await runTicks(CorrectionWindow.tickCount, h)
        let r = try #require(await result(h))
        #expect(r.reason == .timeout)
        #expect(r.match == .changed(Self.fixed))
        #expect(r.source == .final)
        #expect(r.ticks == 30)
        #expect(h.reader.valueCalls == 31)
    }

    @Test func focus_moving_to_another_element_ends_it() async throws {
        let other = FakeAXTextElement(pid: 1)
        let h = makeHarness(focus: { [.value($0.ref), .value($0.ref), .value(other.ref)] })
        h.window.start(inserted: Self.original)
        await runTicks(3, h)
        let r = try #require(await result(h))
        #expect(r.reason == .focusLeft)
        #expect(r.ticks == 2)
        #expect(h.reader.valueCalls == 3)
    }

    @Test func no_focused_element_ends_it() async throws {
        let h = makeHarness(focus: { _ in [.absent] })
        h.window.start(inserted: Self.original)
        await runTicks(1, h)
        #expect(try #require(await result(h)).reason == .focusLeft)
    }

    @Test func a_failed_focus_read_keeps_it_open() async throws {
        let h = makeHarness(focus: { _ in [.failed] })
        h.window.start(inserted: Self.original)
        await runTicks(CorrectionWindow.tickCount, h)
        let r = try #require(await result(h))
        #expect(r.reason == .timeout)
        #expect(r.ticks == 30)
    }

    @Test func a_new_capture_ends_it_without_waiting() async throws {
        let h = makeHarness(values: [.value(Self.fixed)])
        h.window.start(inserted: Self.original)
        #expect(await eventually { h.clock.pendingCount == 1 })
        h.window.endForNewCapture()
        let r = try #require(await result(h))
        #expect(r.reason == .newCapture)
        #expect(r.ticks == 0)
        #expect(r.match == .changed(Self.fixed))
        #expect(await eventually { h.clock.pendingCount == 0 })
    }

    @Test func a_new_capture_before_the_anchor_is_superseded() async {
        let block = DispatchSemaphore(value: 0)
        let h = makeHarness(anchorBlock: block)
        h.window.start(inserted: Self.original)
        #expect(await eventually { h.reader.anchorCalls == 1 })
        h.window.endForNewCapture()
        #expect(h.ends.read() == [.skipped(.superseded)])
        block.signal()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(h.ends.read().count == 1)
        #expect(h.reader.valueCalls == 0)
    }

    @Test func text_not_yet_at_the_caret_is_retried_once() async throws {
        let h = makeHarness(anchors: { [.skipped(.notAtCaret), FakeCorrectionReader.anchored($0, value: Self.original, inserted: Self.original)] })
        h.window.start(inserted: Self.original)
        #expect(await eventually { h.clock.pendingCount == 1 })
        await h.clock.advance(by: CorrectionWindow.anchorRetryDelay)
        #expect(await eventually { h.reader.anchorCalls == 2 && h.clock.pendingCount == 1 })
        h.window.endForNewCapture()
        #expect(try #require(await result(h)).match == .unchanged)
    }

    @Test func a_second_miss_skips_and_other_skips_never_retry() async {
        let missed = makeHarness(anchors: { _ in [.skipped(.notAtCaret)] })
        missed.window.start(inserted: Self.original)
        #expect(await eventually { missed.clock.pendingCount == 1 })
        await missed.clock.advance(by: CorrectionWindow.anchorRetryDelay)
        #expect(await eventually { missed.ends.read() == [.skipped(.notAtCaret)] })

        let secure = makeHarness(anchors: { _ in [.skipped(.secure)] })
        secure.window.start(inserted: Self.original)
        #expect(await eventually { secure.ends.read() == [.skipped(.secure)] })
        #expect(secure.reader.anchorCalls == 1)
    }

    @Test func an_unreadable_final_value_with_no_snapshot_is_unreadable() async throws {
        let h = makeHarness(values: [.failed])
        h.window.start(inserted: Self.original)
        #expect(await eventually { h.clock.pendingCount == 1 })
        h.window.endForNewCapture()
        let r = try #require(await result(h))
        #expect(r.match == .unreadable)
        #expect(r.source == .final)
    }

    @Test func an_emptied_field_after_a_changed_poll_uses_the_last_good_snapshot() async throws {
        let h = makeHarness(values: [.value(Self.fixed), .value("")])
        h.window.start(inserted: Self.original)
        await runTicks(1, h)
        #expect(await eventually { h.clock.pendingCount == 1 })
        h.window.endForNewCapture()
        let r = try #require(await result(h))
        #expect(r.match == .changed(Self.fixed))
        #expect(r.source == .lastGood)
        #expect(r.ticks == 1)
    }

    @Test func an_ambiguous_or_unreadable_final_read_uses_the_last_good_snapshot() async throws {
        let prefixed = makeHarness(
            anchors: { [FakeCorrectionReader.anchored($0, value: "Hi Bob, " + Self.original, inserted: Self.original)] },
            values: [.value("Hi Bob, " + Self.fixed), .value("Hi Rob, " + Self.fixed)]
        )
        prefixed.window.start(inserted: Self.original)
        await runTicks(1, prefixed)
        #expect(await eventually { prefixed.clock.pendingCount == 1 })
        prefixed.window.endForNewCapture()
        let ambiguous = try #require(await result(prefixed))
        #expect(ambiguous.match == .changed(Self.fixed))
        #expect(ambiguous.source == .lastGood)

        let gone = makeHarness(values: [.value(Self.fixed), .failed])
        gone.window.start(inserted: Self.original)
        await runTicks(1, gone)
        #expect(await eventually { gone.clock.pendingCount == 1 })
        gone.window.endForNewCapture()
        #expect(try #require(await result(gone)).source == .lastGood)
    }

    @Test func only_changed_polls_replace_the_snapshot() async throws {
        let h = makeHarness(values: [.value(Self.fixed), .value(Self.original), .value(""), .failed])
        h.window.start(inserted: Self.original)
        await runTicks(3, h)
        #expect(await eventually { h.clock.pendingCount == 1 })
        h.window.endForNewCapture()
        #expect(try #require(await result(h)).match == .changed(Self.fixed))
    }

    @Test func a_later_changed_poll_replaces_an_earlier_one() async throws {
        let h = makeHarness(values: [.value(Self.fixed), .value("ask Kubernetes now"), .failed])
        h.window.start(inserted: Self.original)
        await runTicks(2, h)
        #expect(await eventually { h.clock.pendingCount == 1 })
        h.window.endForNewCapture()
        #expect(try #require(await result(h)).match == .changed("ask Kubernetes now"))
    }

    @Test func a_reverted_edit_ends_unchanged() async throws {
        let h = makeHarness(values: [.value(Self.fixed), .value(Self.original)])
        h.window.start(inserted: Self.original)
        await runTicks(1, h)
        #expect(await eventually { h.clock.pendingCount == 1 })
        h.window.endForNewCapture()
        let r = try #require(await result(h))
        #expect(r.match == .unchanged)
        #expect(r.source == .final)
    }

    @Test func cancel_reports_nothing() async {
        let h = makeHarness()
        h.window.start(inserted: Self.original)
        #expect(await eventually { h.clock.pendingCount == 1 })
        h.window.cancel()
        #expect(await eventually { h.clock.pendingCount == 0 })
        h.window.endForNewCapture()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(h.ends.read().isEmpty)
    }

    @Test func resolve_prefers_a_located_final_read() {
        let table: [(RegionMatch, String?, RegionMatch, WindowResult.Source)] = [
            (.changed("b"), "a", .changed("b"), .final),
            (.unchanged, "a", .unchanged, .final),
            (.discarded, "a", .changed("a"), .lastGood),
            (.ambiguous, "a", .changed("a"), .lastGood),
            (.unreadable, "a", .changed("a"), .lastGood),
            (.discarded, nil, .discarded, .final),
            (.ambiguous, nil, .ambiguous, .final),
            (.unreadable, nil, .unreadable, .final),
        ]
        for (final, lastGood, match, source) in table {
            let resolved = CorrectionWindow.resolve(final: final, lastGood: lastGood)
            #expect(resolved.match == match && resolved.source == source, "\(final), \(String(describing: lastGood))")
        }
    }
}
