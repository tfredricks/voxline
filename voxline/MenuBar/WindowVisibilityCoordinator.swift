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
        // Seed from already-visible titled windows. We do NOT call into the
        // policy logic from start(): LSUIElement starts the app at .accessory,
        // which is exactly where we want to be when no windows are tracked.
        for w in NSApp.windows where isTitled(w) && w.isVisible {
            tracked.insert(ObjectIdentifier(w))
        }

        let key = center.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let w = note.object as? NSWindow, self.isTitled(w) else { return }
                self.insert(w)
            }
        }
        let close = center.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let w = note.object as? NSWindow else { return }
                self.remove(w)
            }
        }
        observers = [key, close]
    }

    private func isTitled(_ w: NSWindow) -> Bool {
        w.styleMask.contains(.titled)
    }

    /// Add `w` to the tracked set. Flip the app to `.regular` only on the
    /// 0 → 1 edge — repeated didBecomeKey events for an already-tracked window
    /// must NOT re-issue `setActivationPolicy(.regular)`, because the
    /// redundant call interrupts AppKit's in-flight activation and produces a
    /// visible flicker on the very window we're trying to show.
    private func insert(_ w: NSWindow) {
        let wasEmpty = tracked.isEmpty
        let inserted = tracked.insert(ObjectIdentifier(w)).inserted
        if wasEmpty && inserted {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
        }
    }

    /// Remove `w` from the tracked set. Flip back to `.accessory` only on the
    /// 1 → 0 edge. Deferred to the next runloop tick so the closing window
    /// finishes ordering out before AppKit re-evaluates the Dock state
    /// (avoids a stuck Dock icon).
    private func remove(_ w: NSWindow) {
        let removed = tracked.remove(ObjectIdentifier(w)) != nil
        if removed && tracked.isEmpty {
            DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
        }
    }

    deinit {
        for o in observers { center.removeObserver(o) }
    }
}
