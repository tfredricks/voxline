import AppKit
import SwiftUI

/// Hosts `PermissionsStatusView` in a dismissable panel. Shown at launch when a
/// required permission is missing, on runtime revocation, or from the menu-bar
/// "Fix permissions…" item. Auto-closes once Accessibility + Microphone are
/// both granted. Unlike the first-run wizard, the user may close it manually.
@MainActor
final class PermissionsWindowController {

    private var window: NSWindow?

    /// Idempotent: raises the existing window if already shown.
    func show() {
        if let window {
            window.presentInAccessoryApp()
            return
        }
        let root = PermissionsStatusView(onRequiredGranted: { [weak self] in
            self?.close()
        })
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "voxline Permissions"
        win.contentView = NSHostingView(rootView: root)
        win.center()
        win.isReleasedWhenClosed = false
        self.window = win
        win.presentInAccessoryApp()
    }

    func close() {
        window?.close()
        window = nil
    }
}
