import AppKit
import SwiftUI

@MainActor
final class AboutWindowController {
    private var window: NSWindow?
    private var host: NSHostingView<AboutView>?

    func show(env: SupportEnvironment, metrics: DictationMetricsStore? = nil) {
        if let w = window {
            host?.rootView = AboutView(env: env, metrics: metrics)
            w.presentInAccessoryApp()
            return
        }
        let host = NSHostingView(rootView: AboutView(env: env, metrics: metrics))
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 500),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "About Voxline"
        win.contentView = host
        self.host = host
        win.center()
        win.isReleasedWhenClosed = false
        self.window = win
        win.presentInAccessoryApp()
    }
}
