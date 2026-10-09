import AppKit
import SwiftUI

/// The elapsed-time chip shown while a meeting records, expandable to the
/// live transcript. Borderless, non-activating, never key or main, on every
/// Space, draggable; its position is remembered. A panel, so `DockPolicy`
/// ignores it.
@MainActor
final class MeetingTimerPanel {

    private static let autosaveName = "voxline.meetingTimer"
    private var panel: NSPanel?
    private var hostingView: NSHostingView<MeetingLivePanelView>?
    private var startedAt = Date()
    private var live: (any LiveMeetingTranscribing)?
    private var expanded = false

    func show(startedAt: Date, live: (any LiveMeetingTranscribing)?) {
        guard panel == nil else { return }
        self.startedAt = startedAt
        self.live = live
        expanded = live != nil && AppSettings().meetingLivePanelExpanded
        let hostingView = NSHostingView(rootView: rootView())
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
        if let screen = Self.screen(for: saved) {
            let size = hostingView.fittingSize
            let frame = saved.map {
                MeetingTimerLayout.resized($0, to: size, visibleFrame: screen.visibleFrame)
            } ?? MeetingTimerLayout.frame(size: size, saved: nil, visibleFrame: screen.visibleFrame)
            panel.setFrame(frame, display: false)
        }
        panel.setFrameAutosaveName(Self.autosaveName)
        panel.orderFrontRegardless()
        self.panel = panel
        self.hostingView = hostingView
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
        hostingView = nil
        live = nil
    }

    private func rootView() -> MeetingLivePanelView {
        MeetingLivePanelView(startedAt: startedAt, live: live, expanded: expanded) { [weak self] in
            self?.toggle()
        }
    }

    private func toggle() {
        expanded.toggle()
        var settings = AppSettings()
        settings.meetingLivePanelExpanded = expanded
        guard let panel, let hostingView else { return }
        hostingView.rootView = rootView()
        hostingView.layoutSubtreeIfNeeded()
        let size = hostingView.fittingSize
        guard let screen = Self.screen(for: panel.frame) else { return }
        panel.setFrame(
            MeetingTimerLayout.resized(panel.frame, to: size, visibleFrame: screen.visibleFrame),
            display: true
        )
    }

    private static func screen(for frame: CGRect?) -> NSScreen? {
        frame.flatMap { frame in NSScreen.screens.first { $0.frame.intersects(frame) } } ?? NSScreen.main
    }
}

private final class ChipPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
