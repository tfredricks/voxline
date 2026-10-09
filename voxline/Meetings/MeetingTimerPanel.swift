import AppKit
import SwiftUI

/// The elapsed-time chip shown while a meeting records. Borderless,
/// non-activating, never key or main, on every Space, draggable; its
/// position is remembered. Untitled, so `WindowVisibilityCoordinator`
/// ignores it.
@MainActor
final class MeetingTimerPanel {

    private static let autosaveName = "voxline.meetingTimer"
    private var panel: NSPanel?

    func show(startedAt: Date) {
        guard panel == nil else { return }
        let size = NSSize(width: 96, height: 28)
        let panel = ChipPanel(
            contentRect: NSRect(origin: .zero, size: size),
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
        panel.contentView = NSHostingView(rootView: MeetingTimerChip(startedAt: startedAt))
        if !panel.setFrameUsingName(Self.autosaveName), let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.maxX - size.width - 16, y: frame.maxY - size.height - 8))
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
            Text(startedAt, style: .timer)
                .monospacedDigit()
                .font(.system(size: 12, weight: .medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Meeting recording")
    }
}
