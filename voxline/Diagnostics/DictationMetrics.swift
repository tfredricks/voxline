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
    /// Finalize entry (just after key release) → last audio sample drained. Near zero until streaming lands in phase 2.
    let captureTailMs: Int
    let transcribeMs: Int
    let cleanupMs: Int
    let insertMs: Int
    /// Finalize entry (just after key release) → text in the field or on the clipboard.
    let totalMs: Int
    let engineID: String
    let modelID: String
    let wordCount: Int
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
        AppLog.metrics.info(
            "\(metrics.kind.rawValue, privacy: .public) audio=\(String(format: "%.1f", metrics.audioDuration), privacy: .public)s tail=\(metrics.captureTailMs)ms transcribe=\(metrics.transcribeMs)ms cleanup=\(metrics.cleanupMs)ms insert=\(metrics.insertMs)ms total=\(metrics.totalMs)ms engine=\(metrics.engineID, privacy: .public) model=\(metrics.modelID, privacy: .public) words=\(metrics.wordCount)"
        )
    }

    func median(_ keyPath: KeyPath<DictationMetrics, Int>) -> Int? {
        let values = items.map { $0[keyPath: keyPath] }.sorted()
        guard !values.isEmpty else { return nil }
        let mid = values.count / 2
        return values.count.isMultiple(of: 2) ? (values[mid - 1] + values[mid]) / 2 : values[mid]
    }
}
