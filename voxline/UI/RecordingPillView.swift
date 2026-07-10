import SwiftUI

/// Small floating pill showing recording state, an animated waveform, or —
/// after a dictation completes — quick refinement actions.
struct RecordingPillView: View {
    @Bindable var state: AppState
    var actions: PillReviewActions = PillReviewActions()

    var body: some View {
        Group {
            switch state.status {
            case .recording:
                HStack(spacing: 10) {
                    WaveformBars(level: state.audioLevel)
                    Text(elapsed)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .monospacedDigit()
                }
            case .thinking:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(state.reviewSession != nil ? "Refining…" : "Transcribing…")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                }
            default:
                if state.reviewSession != nil {
                    ReviewControls(state: state, actions: actions)
                } else if let toast = state.toastMessage {
                    Text(toast)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                } else {
                    EmptyView()
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .frame(height: 32)
    }

    private var elapsed: String {
        guard let startedAt = state.recordingStartedAt else { return "0.0s" }
        let s = Date().timeIntervalSince(startedAt)
        return String(format: "%.1fs", s)
    }
}

/// The three refinement buttons + dismiss. Hovering anywhere over the row
/// pauses the auto-dismiss countdown. An optional caption line surfaces the
/// "Copied — ⌘V to replace" / error toast without hiding the buttons.
private struct ReviewControls: View {
    @Bindable var state: AppState
    let actions: PillReviewActions

    var body: some View {
        VStack(spacing: 2) {
            if let toast = state.toastMessage {
                Text(toast)
                    .font(.system(size: 10, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                button("Terser") { actions.refine(.terser) }
                button("Longer") { actions.refine(.longer) }
                button("Clearer") { actions.refine(.clearer) }
                Button(action: { actions.dismiss() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }
        }
        .onHover { actions.hoverChanged($0) }
    }

    private func button(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .buttonStyle(.plain)
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
