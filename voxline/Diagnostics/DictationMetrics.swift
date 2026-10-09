import Foundation
import Observation

/// Timing breakdown of one dictation or command, from key release to text in
/// the field. Phase 2's latency targets are set against medians of these.
struct DictationMetrics: Equatable, Sendable {

    enum Kind: String, Sendable {
        case dictation
        case command
    }

    let timestamp: Date
    let kind: Kind
    let audioDuration: TimeInterval
    /// Key release → capture stopped, with the resampler tail delivered.
    let captureTailMs: Int
    /// The session's `finish()` call → final text.
    let transcribeMs: Int
    let cleanupMs: Int
    let insertMs: Int
    /// Key release → text in the field or on the clipboard.
    let totalMs: Int
    let engineID: String
    let modelID: String
    let wordCount: Int
    /// Recording start → first non-empty live partial; nil when none arrived.
    let firstPartialMs: Int?
    /// True when the fast path inserted the engine text without LLM cleanup.
    let skippedCleanup: Bool
}

@Observable
@MainActor
final class DictationMetricsStore {

    static let capacity = 50

    private(set) var items: [DictationMetrics] = []

    /// `nonisolated` so `CapturePipeline.init` can use it as a default argument,
    /// which Swift 5 mode evaluates outside the main actor.
    nonisolated init() {}

    func record(_ metrics: DictationMetrics) {
        items.insert(metrics, at: 0)
        if items.count > Self.capacity {
            items.removeLast(items.count - Self.capacity)
        }
        let firstPartial = metrics.firstPartialMs.map(String.init) ?? "-"
        AppLog.metrics.info(
            "\(metrics.kind.rawValue, privacy: .public) audio=\(String(format: "%.1f", metrics.audioDuration), privacy: .public)s tail=\(metrics.captureTailMs)ms transcribe=\(metrics.transcribeMs)ms cleanup=\(metrics.cleanupMs)ms insert=\(metrics.insertMs)ms total=\(metrics.totalMs)ms engine=\(metrics.engineID, privacy: .public) model=\(metrics.modelID, privacy: .public) words=\(metrics.wordCount) firstPartial=\(firstPartial, privacy: .public)ms skipCleanup=\(metrics.skippedCleanup)"
        )
    }

    func count(kind: DictationMetrics.Kind = .dictation) -> Int {
        items.lazy.filter { $0.kind == kind }.count
    }

    /// Median over rows of `kind`. `excludingZero` skips rows where the value
    /// is 0, e.g. inserts that took the copy path.
    func median(_ keyPath: KeyPath<DictationMetrics, Int>, kind: DictationMetrics.Kind = .dictation, excludingZero: Bool = false) -> Int? {
        Self.median(of: items.filter { $0.kind == kind }.map { $0[keyPath: keyPath] }.filter { !excludingZero || $0 != 0 })
    }

    /// Median over rows of `kind` that have a value.
    func median(_ keyPath: KeyPath<DictationMetrics, Int?>, kind: DictationMetrics.Kind = .dictation) -> Int? {
        Self.median(of: items.filter { $0.kind == kind }.compactMap { $0[keyPath: keyPath] })
    }

    private static func median(of values: [Int]) -> Int? {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return nil }
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}
