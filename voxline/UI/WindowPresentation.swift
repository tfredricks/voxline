import AppKit

@MainActor
extension NSWindow {
    /// Activate the app and bring this window forward with the sequence
    /// required by LSUIElement (menu-bar) apps. Activate BEFORE ordering the
    /// window so the activation-policy flip lands before AppKit decides
    /// z-order; otherwise the window appears behind whatever app was
    /// previously frontmost. `ignoringOtherApps: true` is deprecated but
    /// still the documented escape hatch for accessory apps —
    /// `NSApp.activate()` alone is unreliable here.
    func presentInAccessoryApp() {
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
    }
}
