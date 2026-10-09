import AppKit
import SwiftUI

/// Hosts RecordingPillView in a click-through, non-activating NSPanel anchored
/// bottom-center on the screen that held the mouse when the pill appeared.
/// The panel takes clicks only while it offers Retry after an error.
@MainActor
final class RecordingPillWindow {
    private var panel: NSPanel?
    private var hostingView: PillHostingView?
    private var anchorScreen: NSScreen?
    private var retryTimer: Timer?
    private var observedStatus: AppStatus?

    /// Invoked by the pill's Retry button.
    var onRetry: (() -> Void)?

    /// When the current error stops offering Retry; nil while none is offered.
    /// Any status change withdraws the offer.
    private(set) var retryUntil: Date?

    func show(state: AppState) {
        if panel != nil {
            updateVisibility(state: state)
            return
        }

        let view = RecordingPillView(state: state)
        let host = PillHostingView(rootView: view)
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
        updateRetryOffer(state: state)
        let content = PillLayout.content(status: state.status, hasToast: state.toastMessage != nil, retryOffered: retryUntil != nil)
        panel.ignoresMouseEvents = content != .retry
        updateRootView(state: state, retryVisible: content == .retry)
        guard content != .hidden else {
            if panel.isVisible {
                panel.orderOut(nil)
                anchorScreen = nil
            }
            return
        }

        let showsText = PillLayout.showsText(content: content, hasText: state.liveTranscript?.isEmpty == false)
        let compactWidth: CGFloat?
        switch content {
        case .toast:
            compactWidth = state.toastMessage.map(Self.toastTextWidth)
        case .retry:
            let message = PillLayout.firstSentence(state.status.errorMessage ?? "")
            compactWidth = Self.toastTextWidth(message) + PillLayout.retrySpacing + PillLayout.retryButtonWidth
        case .recording, .thinking, .hidden:
            compactWidth = nil
        }
        let size = PillLayout.size(showsText: showsText, toastWidth: compactWidth)

        if !panel.isVisible {
            anchorScreen = Self.screenUnderMouse()
            anchor(panel, size: size)
            panel.orderFrontRegardless()
        } else if panel.frame.size != size {
            anchor(panel, size: size)
        }
    }

    func close() {
        retryTimer?.invalidate()
        retryTimer = nil
        retryUntil = nil
        panel?.orderOut(nil)
        panel = nil
        hostingView = nil
        anchorScreen = nil
    }

    /// Starts an offer when status becomes an error with a retryable
    /// transcript; withdraws it on any other status change or when it expires.
    private func updateRetryOffer(state: AppState) {
        if let retryUntil, Date() >= retryUntil {
            withdrawRetryOffer()
        }
        guard state.status != observedStatus else { return }
        observedStatus = state.status
        withdrawRetryOffer()
        guard PillLayout.offersRetry(status: state.status, hasRetryTranscript: state.retryTranscript != nil) else { return }
        retryUntil = Date().addingTimeInterval(PillLayout.retryDuration)
        retryTimer = Timer.scheduledTimer(withTimeInterval: PillLayout.retryDuration, repeats: false) { [weak self, weak state] _ in
            MainActor.assumeIsolated {
                guard let self, let state else { return }
                self.withdrawRetryOffer()
                self.updateVisibility(state: state)
            }
        }
    }

    private func withdrawRetryOffer() {
        retryTimer?.invalidate()
        retryTimer = nil
        retryUntil = nil
    }

    private func updateRootView(state: AppState, retryVisible: Bool) {
        guard let hostingView, hostingView.rootView.retryVisible != retryVisible else { return }
        hostingView.rootView = RecordingPillView(state: state, onRetry: onRetry, retryVisible: retryVisible)
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

    private static let toastWidthSlack: CGFloat = 4

    /// Width of `toast` in the font `RecordingPillView` draws it in.
    private static func toastTextWidth(_ toast: String) -> CGFloat {
        let base = NSFont.systemFont(ofSize: 11, weight: .medium)
        let font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 11) } ?? base
        let width = NSAttributedString(string: toast, attributes: [.font: font]).size().width
        return ceil(width) + toastWidthSlack
    }
}

/// Delivers the first click to the Retry button even though the
/// non-activating panel never becomes key.
private final class PillHostingView: NSHostingView<RecordingPillView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
