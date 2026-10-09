import Foundation

enum WindowEndReason: String, Sendable {
    case timeout, focusLeft, newCapture
}

struct WindowResult: Equatable, Sendable {
    enum Source: String, Sendable {
        case final, lastGood
    }

    let reason: WindowEndReason
    let anchor: AnchorText
    let match: RegionMatch
    let source: Source
    /// Completed polls that found focus still on the field.
    let ticks: Int
}

enum WindowEnd: Equatable, Sendable {
    case skipped(AnchorSkip)
    case finished(WindowResult)
}

private enum WindowPoll: Sendable {
    case focusLeft
    case stayed(RegionMatch)
}

/// One correction window after a dictation insert: anchor the text, poll the
/// field once a second for `tickCount` seconds (focus, value, locate), keep
/// the last poll whose region was located and changed, then read the value
/// once more. Reports exactly one `WindowEnd`, unless cancelled. Every AX
/// read runs detached.
@MainActor
final class CorrectionWindow {

    static let tickCount = 30
    static let tick: Duration = .seconds(1)
    static let anchorRetryDelay: Duration = .milliseconds(300)

    private enum Phase { case running, finishing, done }

    private let reader: any CorrectionReading
    private let sleep: @Sendable (Duration) async throws -> Void
    private let onEnd: @MainActor (WindowEnd) -> Void
    private var phase = Phase.running
    private var task: Task<Void, Never>?
    private var anchor: InsertAnchor?
    private var lastGood: String?
    private var ticks = 0

    init(reader: any CorrectionReading,
         sleep: @escaping @Sendable (Duration) async throws -> Void,
         onEnd: @escaping @MainActor (WindowEnd) -> Void) {
        self.reader = reader
        self.sleep = sleep
        self.onEnd = onEnd
    }

    func start(inserted: String) {
        task = Task { [weak self] in await self?.run(inserted: inserted) }
    }

    /// Ends the window for a new capture: stops polling and starts the final
    /// read without waiting for it. Before the anchor exists, ends as
    /// `.skipped(.superseded)`.
    func endForNewCapture() {
        guard phase == .running else { return }
        task?.cancel()
        guard let anchor else {
            finish(.skipped(.superseded))
            return
        }
        phase = .finishing
        Task { await self.readFinal(.newCapture, anchor: anchor) }
    }

    /// Stops with no final read and no report.
    func cancel() {
        phase = .done
        task?.cancel()
    }

    /// A located final read wins; otherwise the last `.changed` poll, if
    /// any, stands in for it.
    nonisolated static func resolve(final: RegionMatch, lastGood: String?) -> (match: RegionMatch, source: WindowResult.Source) {
        switch final {
        case .changed, .unchanged:
            return (final, .final)
        case .discarded, .ambiguous, .unreadable:
            guard let lastGood else { return (final, .final) }
            return (.changed(lastGood), .lastGood)
        }
    }

    nonisolated static func locate(_ anchor: InsertAnchor, with reader: any CorrectionReading) -> RegionMatch {
        guard let value = reader.value(of: anchor.element).value else { return .unreadable }
        return RegionLocator.locate(anchor.text, in: value)
    }

    private func run(inserted: String) async {
        var read = await Self.readAnchor(reader, inserted)
        if read.skipped == .notAtCaret {
            do { try await sleep(Self.anchorRetryDelay) } catch { return }
            guard phase == .running else { return }
            read = await Self.readAnchor(reader, inserted)
        }
        guard phase == .running else { return }
        guard case .anchored(let anchor) = read else {
            if let reason = read.skipped { finish(.skipped(reason)) }
            return
        }
        self.anchor = anchor

        for _ in 0..<Self.tickCount {
            do { try await sleep(Self.tick) } catch { return }
            guard phase == .running else { return }
            let poll = await Self.poll(reader, anchor)
            guard phase == .running else { return }
            switch poll {
            case .focusLeft:
                await beginFinal(.focusLeft, anchor: anchor)
                return
            case .stayed(let match):
                ticks += 1
                if case .changed(let text) = match { lastGood = text }
            }
        }
        await beginFinal(.timeout, anchor: anchor)
    }

    private func beginFinal(_ reason: WindowEndReason, anchor: InsertAnchor) async {
        guard phase == .running else { return }
        phase = .finishing
        await readFinal(reason, anchor: anchor)
    }

    private func readFinal(_ reason: WindowEndReason, anchor: InsertAnchor) async {
        let reader = self.reader
        let final = await Task.detached(priority: .utility) { CorrectionWindow.locate(anchor, with: reader) }.value
        guard phase == .finishing else { return }
        let resolved = Self.resolve(final: final, lastGood: lastGood)
        finish(.finished(WindowResult(
            reason: reason, anchor: anchor.text, match: resolved.match, source: resolved.source, ticks: ticks
        )))
    }

    private func finish(_ end: WindowEnd) {
        guard phase != .done else { return }
        phase = .done
        onEnd(end)
    }

    private nonisolated static func readAnchor(_ reader: any CorrectionReading, _ inserted: String) async -> AnchorRead {
        await Task.detached(priority: .utility) { reader.anchor(for: inserted) }.value
    }

    private nonisolated static func poll(_ reader: any CorrectionReading, _ anchor: InsertAnchor) async -> WindowPoll {
        await Task.detached(priority: .utility) { () -> WindowPoll in
            switch reader.focusedRef() {
            case .value(let ref) where ref != anchor.element.ref: return .focusLeft
            case .absent: return .focusLeft
            default: return .stayed(CorrectionWindow.locate(anchor, with: reader))
            }
        }.value
    }
}
