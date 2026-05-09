import SwiftUI

// PLAN 2 ONLY — REMOVED IN PLAN 3 ONCE PASTE LANDS.
// This window shows recent transcripts so we can verify the capture pipeline
// without the LLM cleanup or paste yet wired up.
struct DebugTranscriptWindow: View {
    @Bindable var state: AppState
    @State private var history: [TranscriptEntry] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("voxline — transcripts (Plan 2 debug)")
                .font(.headline)
            Divider()

            if history.isEmpty {
                Text("No transcripts yet. Hold Left Ctrl + Left Option, speak, release.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(history) { entry in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.timestamp, style: .time)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(entry.text)
                                    .textSelection(.enabled)
                            }
                            .padding(.vertical, 4)
                            Divider()
                        }
                    }
                }
            }
        }
        .padding()
        .frame(minWidth: 480, minHeight: 320)
        .onChange(of: state.lastTranscript) { _, newValue in
            guard let text = newValue, !text.isEmpty else { return }
            history.insert(TranscriptEntry(text: text, timestamp: Date()), at: 0)
            // Keep at most 20 entries.
            if history.count > 20 { history.removeLast(history.count - 20) }
        }
    }
}

private struct TranscriptEntry: Identifiable {
    let id = UUID()
    let text: String
    let timestamp: Date
}
