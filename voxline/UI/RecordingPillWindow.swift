import AppKit
import SwiftUI

/// Hosts RecordingPillView in a click-through, non-activating NSPanel.
@MainActor
final class RecordingPillWindow {
    private var panel: NSPanel?
    private var hostingView: NSHostingView<RecordingPillView>?

    func show(state: AppState) {
        if panel != nil {
            updateVisibility(state: state)
            return
        }

        let view = RecordingPillView(state: state)
        let host = NSHostingView(rootView: view)
        hostingView = host

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 140, height: 32),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true   // click-through
        panel.contentView = host

        repositionNearMouse(panel: panel)

        self.panel = panel
        updateVisibility(state: state)
    }

    func updateVisibility(state: AppState) {
        guard let panel else { return }
        switch state.status {
        case .recording, .thinking:
            if !panel.isVisible {
                repositionNearMouse(panel: panel)
                panel.orderFrontRegardless()
            }
        default:
            panel.orderOut(nil)
        }
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
        hostingView = nil
    }

    private func repositionNearMouse(panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let size = panel.frame.size
        // Place pill just below the cursor, horizontally centered.
        let origin = NSPoint(x: mouse.x - size.width / 2, y: mouse.y - size.height - 24)
        panel.setFrameOrigin(origin)
    }
}
