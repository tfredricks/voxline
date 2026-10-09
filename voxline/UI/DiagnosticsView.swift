import SwiftUI

/// Latency breakdown of the last run, medians over the retained dictations,
/// and median totals for commands and presets. Lives in the About window so
/// bug reports can quote it.
struct DiagnosticsView: View {
    let metrics: DictationMetricsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Diagnostics")
                .fontWeight(.semibold)
            if let last = metrics.items.first {
                Text("Last: \(Self.line(total: last.totalMs, transcribe: last.transcribeMs, cleanup: last.cleanupMs, insert: last.insertMs))")
                if let total = metrics.median(\.totalMs, kind: .dictation),
                   let transcribe = metrics.median(\.transcribeMs, kind: .dictation),
                   let cleanup = metrics.median(\.cleanupMs, kind: .dictation) {
                    let insert = metrics.median(\.insertMs, kind: .dictation, excludingZero: true) ?? 0
                    Text("Median of \(metrics.count(kind: .dictation)) dictations: \(Self.line(total: total, transcribe: transcribe, cleanup: cleanup, insert: insert))")
                }
                if let firstWords = metrics.median(\.firstPartialMs, kind: .dictation) {
                    Text("First words: \(Self.seconds(firstWords))")
                }
                if let total = metrics.median(\.totalMs, kind: .command) {
                    Text("Median of \(metrics.count(kind: .command)) commands: \(Self.seconds(total)) total")
                }
                if let total = metrics.median(\.totalMs, kind: .preset) {
                    Text("Median of \(metrics.count(kind: .preset)) presets: \(Self.seconds(total)) total")
                }
                Text("Engine \(last.engineID) · Model \(last.modelID)")
            } else {
                Text("No dictations yet.")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func line(total: Int, transcribe: Int, cleanup: Int, insert: Int) -> String {
        "\(seconds(total)) total · transcribe \(seconds(transcribe)) · cleanup \(seconds(cleanup)) · insert \(seconds(insert))"
    }

    static func seconds(_ milliseconds: Int) -> String {
        String(format: "%.2fs", Double(milliseconds) / 1000)
    }
}
