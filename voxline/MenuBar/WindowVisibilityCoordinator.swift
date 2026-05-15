import AppKit

/// Flips the app between `.regular` (Dock icon visible) and `.accessory`
/// (menu-bar only) based on whether any titled window is currently visible.
/// HUD windows (recording pill, model download) are borderless and are
/// excluded automatically by the `.titled` style-mask check.
@MainActor
final class WindowVisibilityCoordinator {
    private let center: NotificationCenter
    private var observers: [NSObjectProtocol] = []
    private var tracked: Set<ObjectIdentifier> = []

    init(center: NotificationCenter = .default) {
        self.center = center
    }

    func start() {
        for w in NSApp.windows where isTitled(w) && w.isVisible {
            tracked.insert(ObjectIdentifier(w))
        }
        reconcile()

        let key = center.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let w = note.object as? NSWindow, self.isTitled(w) else { return }
                self.tracked.insert(ObjectIdentifier(w))
                self.reconcile()
            }
        }
        let close = center.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let w = note.object as? NSWindow else { return }
                self.tracked.remove(ObjectIdentifier(w))
                self.reconcile()
            }
        }
        observers = [key, close]
    }

    private func isTitled(_ w: NSWindow) -> Bool {
        w.styleMask.contains(.titled)
    }

    private func reconcile() {
        let policy: NSApplication.ActivationPolicy = tracked.isEmpty ? .accessory : .regular
        // Defer to next runloop tick when going .accessory so a closing
        // window has time to finish ordering out before AppKit re-evaluates
        // the Dock state (avoids a stuck Dock icon).
        if policy == .accessory {
            DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
        } else {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
        }
    }

    deinit {
        for o in observers { center.removeObserver(o) }
    }
}
