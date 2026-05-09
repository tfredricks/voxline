import SwiftUI

/// Small floating pill showing recording state and an animated waveform.
struct RecordingPillView: View {
    @Bindable var state: AppState

    var body: some View {
        HStack(spacing: 10) {
            switch state.status {
            case .recording:
                WaveformBars(level: state.audioLevel)
                Text(elapsed)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .monospacedDigit()
            case .thinking:
                ProgressView()
                    .controlSize(.small)
                Text("Transcribing…")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
            default:
                EmptyView()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .frame(width: 140, height: 32)
    }

    private var elapsed: String {
        guard let startedAt = state.recordingStartedAt else { return "0.0s" }
        let s = Date().timeIntervalSince(startedAt)
        return String(format: "%.1fs", s)
    }
}

private struct WaveformBars: View {
    let level: Float
    @State private var phase: Double = 0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let now = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2) {
                ForEach(0..<5, id: \.self) { i in
                    Capsule()
                        .frame(width: 3, height: barHeight(forIndex: i, time: now))
                        .foregroundStyle(.primary)
                }
            }
        }
    }

    private func barHeight(forIndex i: Int, time: Double) -> CGFloat {
        let phaseOffset = Double(i) * 0.6
        let wave = (sin(time * 6 + phaseOffset) + 1) / 2  // 0...1
        let scaled = CGFloat(level) * (0.4 + 0.6 * CGFloat(wave))
        return max(4, min(16, 16 * scaled))
    }
}
