import SwiftUI

/// Floating pill showing the recording state with the live transcript, the
/// post-recording phase, or a transient toast.
struct RecordingPillView: View {
    @Bindable var state: AppState
    /// Invoked by the pill's Retry button; nil while nothing can be retried.
    var onRetry: (() -> Void)? = nil
    /// Whether the window is currently offering Retry for the last dictation.
    var retryVisible: Bool = false

    var body: some View {
        let content = PillLayout.content(status: state.status, hasToast: state.toastMessage != nil)
        let showsText = PillLayout.showsText(content: content, hasText: transcript != nil)
        Group {
            switch content {
            case .recording: recordingView
            case .thinking:  thinkingView
            case .toast:     toastView
            case .hidden:    EmptyView()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: showsText ? .topLeading : .center)
        .background(.ultraThinMaterial, in: showsText ? AnyShape(RoundedRectangle(cornerRadius: 14)) : AnyShape(Capsule()))
    }

    private var transcript: TranscriptPartial? {
        guard let partial = state.liveTranscript, !partial.isEmpty else { return nil }
        return partial
    }

    private var recordingView: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                WaveformBars(level: state.audioLevel)
                if state.recordingIsCommand {
                    Text("Command")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Text(elapsed)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .monospacedDigit()
            }
            .frame(height: 16)
            if let transcript {
                transcriptText(transcript)
            }
        }
    }

    private var thinkingView: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(phaseLabel)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
            }
            if let transcript {
                Text(transcript.text)
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.head)
            }
        }
    }

    @ViewBuilder
    private var toastView: some View {
        if let toast = state.toastMessage {
            Text(toast)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .lineLimit(1)
        }
    }

    private func transcriptText(_ partial: TranscriptPartial) -> some View {
        let segments = PillLayout.transcriptSegments(partial)
        return Text("\(Text(segments.primary))\(Text(segments.secondary).foregroundStyle(.secondary))")
            .font(.system(size: 12, weight: .regular, design: .rounded))
            .lineLimit(2)
            .truncationMode(.head)
    }

    private var phaseLabel: String {
        switch state.pipelinePhase {
        case .transcribing, nil: return "Transcribing…"
        case .cleaning:          return "Cleaning up…"
        case .inserting:         return "Inserting…"
        }
    }

    private var elapsed: String {
        guard let startedAt = state.recordingStartedAt else { return PillLayout.elapsedLabel(0) }
        return PillLayout.elapsedLabel(Date().timeIntervalSince(startedAt))
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
