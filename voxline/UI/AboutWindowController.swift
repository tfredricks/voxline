import AppKit
import SwiftUI

@MainActor
final class AboutWindowController {
    private var window: NSWindow?

    func show(env: SupportEnvironment) {
        if let w = window {
            w.presentInAccessoryApp()
            return
        }
        let host = NSHostingView(rootView: AboutView(env: env))
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "About Voxline"
        win.contentView = host
        win.center()
        win.isReleasedWhenClosed = false
        self.window = win
        win.presentInAccessoryApp()
    }
}
