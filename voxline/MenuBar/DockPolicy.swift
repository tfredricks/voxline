import AppKit

struct WindowSnapshot: Equatable {
    var isTitled: Bool
    var isPanel: Bool
    var level: NSWindow.Level
    var isVisible: Bool
    var isMiniaturized: Bool
}

extension WindowSnapshot {
    @MainActor init(_ window: NSWindow) {
        self.init(
            isTitled: window.styleMask.contains(.titled),
            isPanel: window is NSPanel,
            level: window.level,
            isVisible: window.isVisible,
            isMiniaturized: window.isMiniaturized
        )
    }
}

/// Whether voxline should show a Dock icon. Panels (alerts, open panels,
/// the recording pill, the meeting timer) never count, so a panel that is
/// ordered out instead of closed can't leave the icon behind.
enum DockPolicy {
    static func policy(showInDock: Bool, windows: [WindowSnapshot]) -> NSApplication.ActivationPolicy {
        if showInDock { return .regular }
        let hasAppWindow = windows.contains { w in
            w.isTitled && !w.isPanel && w.level == .normal && (w.isVisible || w.isMiniaturized)
        }
        return hasAppWindow ? .regular : .accessory
    }
}
