import SwiftUI

/// Latency breakdown of the last dictation and medians over the retained
/// history. Lives in the About window so bug reports can quote it.
struct DiagnosticsView: View {
    let metrics: DictationMetricsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Diagnostics")
                .fontWeight(.semibold)
            if let last = metrics.items.first {
                Text("Last: \(Self.line(total: last.totalMs, transcribe: last.transcribeMs, cleanup: last.cleanupMs, insert: last.insertMs))")
                if let total = metrics.median(\.totalMs),
                   let transcribe = metrics.median(\.transcribeMs),
                   let cleanup = metrics.median(\.cleanupMs),
                   let insert = metrics.median(\.insertMs) {
                    Text("Median of \(metrics.items.count): \(Self.line(total: total, transcribe: transcribe, cleanup: cleanup, insert: insert))")
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
