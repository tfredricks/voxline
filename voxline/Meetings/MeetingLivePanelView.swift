import SwiftUI

/// The timer chip, plus the live transcript body when expanded.
struct MeetingLivePanelView: View {
    let startedAt: Date
    let live: (any LiveMeetingTranscribing)?
    let expanded: Bool
    let onToggle: () -> Void

    private var showsBody: Bool { expanded && live != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if showsBody, let live {
                Divider().padding(.horizontal, 10)
                LiveTranscriptBody(live: live)
                    .frame(width: MeetingTimerLayout.bodySize.width, height: MeetingTimerLayout.bodySize.height)
            }
        }
        .background(.regularMaterial, in: shape)
        .accessibilityElement(children: .contain)
    }

    private var shape: AnyShape {
        showsBody ? AnyShape(RoundedRectangle(cornerRadius: 12, style: .continuous)) : AnyShape(Capsule())
    }

    private var header: some View {
        HStack(spacing: 6) {
            Circle().fill(.red).frame(width: 8, height: 8)
            ZStack {
                Text(MeetingTimerLayout.widestLabel).hidden()
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    Text(MeetingTimerLayout.label(elapsed: context.date.timeIntervalSince(startedAt)))
                }
            }
            .monospacedDigit()
            .font(.system(size: 12, weight: .medium))
            .fixedSize()
            if live != nil {
                if showsBody { Spacer(minLength: 0) }
                Button(action: onToggle) {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(expanded ? "Hide live transcript" : "Show live transcript")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(width: showsBody ? MeetingTimerLayout.bodySize.width : nil, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Meeting recording")
    }
}

private struct LiveTranscriptBody: View {
    let live: any LiveMeetingTranscribing

    private static let bottomID = "bottom"

    var body: some View {
        switch live.availability {
        case .preparing:
            placeholder("Preparing Apple Speech…")
        case .unavailable(let reason):
            placeholder("Live transcript unavailable: \(reason)")
        case .listening where live.transcript.lines.isEmpty && live.transcript.volatile.isEmpty:
            placeholder("Listening…")
        case .listening:
            lines
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(10)
    }

    private var lines: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(live.transcript.lines) { line in
                        row(label: line.track.liveLabel, text: line.text, dim: false)
                    }
                    ForEach([MeetingRecorder.Track.mic, .system], id: \.self) { track in
                        if let tail = live.transcript.volatile[track] {
                            row(label: track.liveLabel, text: tail, dim: true)
                        }
                    }
                    Color.clear.frame(height: 1).id(Self.bottomID)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onAppear { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            .onChange(of: live.transcript) { _, _ in proxy.scrollTo(Self.bottomID, anchor: .bottom) }
        }
    }

    private func row(label: String, text: String, dim: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            if live.showsLabels {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(dim ? .tertiary : .primary)
                .textSelection(.disabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(live.showsLabels ? "\(label): \(text)" : text)
    }
}
