// voxline/UI/HistoryWindowController.swift
//
// Hosts HistoryView in a regular activating NSWindow. Same pattern as
// AboutWindowController and DebugWindowController: lazy-create on first
// show, just bring forward on subsequent calls.

import AppKit
import SwiftUI

@MainActor
final class HistoryWindowController {
    private var window: NSWindow?

    func show(store: DictationHistoryStore, state: AppState) {
        if let w = window {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }
        let host = NSHostingController(rootView: HistoryView(store: store, state: state))
        let win = NSWindow(contentViewController: host)
        win.title = "Voxline History"
        win.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        win.setContentSize(NSSize(width: 920, height: 480))
        win.isReleasedWhenClosed = false
        win.center()
        win.identifier = WindowVisibilityCoordinator.dockworthyIdentifier
        self.window = win
        // See AboutWindowController.show for why this pair is in this order.
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }
}
