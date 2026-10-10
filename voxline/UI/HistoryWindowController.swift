import AppKit
import SwiftUI

/// The History window. Built fresh from `content` on each `show` after a
/// close, and released on close, so a reopened window shows current relative
/// times. It reopens where it was closed while the app runs.
@MainActor
final class HistoryWindowController {
    private(set) var window: NSWindow?
    private let content: @MainActor (DictationHistoryStore, AppState) -> AnyView
    private var closeObserver: NSObjectProtocol?
    private var lastFrame: NSRect?

    init(
        content: @escaping @MainActor (DictationHistoryStore, AppState) -> AnyView = {
            AnyView(HistoryView(store: $0, state: $1))
        }
    ) {
        self.content = content
    }

    func show(store: DictationHistoryStore, state: AppState) {
        if let window {
            window.presentInAccessoryApp()
            return
        }
        let host = NSHostingController(rootView: content(store, state))
        let win = NSWindow(contentViewController: host)
        win.title = "Voxline History"
        win.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        win.isReleasedWhenClosed = false
        if let lastFrame {
            win.setFrame(lastFrame, display: false)
        } else {
            win.setContentSize(NSSize(width: 920, height: 480))
            win.center()
        }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: win, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.releaseWindow() }
        }
        self.window = win
        win.presentInAccessoryApp()
    }

    private func releaseWindow() {
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
        }
        closeObserver = nil
        guard let win = window else { return }
        lastFrame = win.frame
        win.contentViewController = nil
        window = nil
    }
}
