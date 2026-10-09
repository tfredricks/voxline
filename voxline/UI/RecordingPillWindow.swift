import AppKit
import SwiftUI

/// Hosts RecordingPillView in a click-through, non-activating NSPanel anchored
/// bottom-center on the screen that held the mouse when the pill appeared.
@MainActor
final class RecordingPillWindow {
    private var panel: NSPanel?
    private var hostingView: NSHostingView<RecordingPillView>?
    private var anchorScreen: NSScreen?

    func show(state: AppState) {
        if panel != nil {
            updateVisibility(state: state)
            return
        }

        let view = RecordingPillView(state: state)
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        hostingView = host

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: PillLayout.size(showsText: false, toastWidth: nil)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true   // click-through
        panel.contentView = host

        self.panel = panel
        updateVisibility(state: state)
    }

    func updateVisibility(state: AppState) {
        guard let panel else { return }
        let content = PillLayout.content(status: state.status, hasToast: state.toastMessage != nil)
        guard content != .hidden else {
            panel.orderOut(nil)
            anchorScreen = nil
            return
        }

        let showsText = PillLayout.showsText(content: content, hasText: state.liveTranscript?.isEmpty == false)
        let toastWidth = content == .toast ? state.toastMessage.map(Self.toastTextWidth) : nil
        let size = PillLayout.size(showsText: showsText, toastWidth: toastWidth)

        if !panel.isVisible {
            anchorScreen = Self.screenUnderMouse()
            anchor(panel, size: size)
            panel.orderFrontRegardless()
        } else if panel.frame.size != size {
            anchor(panel, size: size)
        }
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
        hostingView = nil
        anchorScreen = nil
    }

    private func anchor(_ panel: NSPanel, size: CGSize) {
        if let screen = anchorScreen, !NSScreen.screens.contains(screen) {
            anchorScreen = Self.screenUnderMouse()
        }
        guard let visibleFrame = anchorScreen?.visibleFrame else {
            panel.setContentSize(size)
            return
        }
        let origin = PillLayout.origin(for: size, in: visibleFrame)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private static func screenUnderMouse() -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
    }

    private static func toastTextWidth(_ toast: String) -> CGFloat {
        NSAttributedString(
            string: toast,
            attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium)]
        ).size().width
    }
}
