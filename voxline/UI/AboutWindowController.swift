import AppKit
import SwiftUI

@MainActor
final class AboutWindowController {
    private var window: NSWindow?

    func show(env: SupportEnvironment) {
        if let w = window {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
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
        // LSUIElement (menu-bar) apps: activate BEFORE ordering the window so
        // the policy flip lands before AppKit decides z-order, otherwise the
        // window appears behind whatever app was previously frontmost.
        // `ignoringOtherApps: true` is deprecated but still the documented
        // escape hatch for accessory apps; `NSApp.activate()` alone is
        // unreliable here.
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }
}
