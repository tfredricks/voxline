import AppKit
import SwiftUI

/// The elapsed-time chip shown while a meeting records. Borderless,
/// non-activating, never key or main, on every Space, draggable; its
/// position is remembered. A panel, so `DockPolicy` ignores it.
@MainActor
final class MeetingTimerPanel {

    private static let autosaveName = "voxline.meetingTimer"
    private var panel: NSPanel?

    func show(startedAt: Date) {
        guard panel == nil else { return }
        let hostingView = NSHostingView(rootView: MeetingTimerChip(startedAt: startedAt))
        let panel = ChipPanel(
            contentRect: NSRect(origin: .zero, size: hostingView.fittingSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.contentView = hostingView
        let saved = panel.setFrameUsingName(Self.autosaveName) ? panel.frame : nil
        let screen = saved.flatMap { saved in NSScreen.screens.first { $0.frame.intersects(saved) } } ?? NSScreen.main
        if let screen {
            let frame = MeetingTimerLayout.frame(
                size: hostingView.fittingSize, saved: saved, visibleFrame: screen.visibleFrame
            )
            panel.setFrame(frame, display: false)
        }
        panel.setFrameAutosaveName(Self.autosaveName)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}

private final class ChipPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct MeetingTimerChip: View {
    let startedAt: Date

    var body: some View {
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
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Meeting recording")
    }
}
