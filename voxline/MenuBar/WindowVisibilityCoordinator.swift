import AppKit

// MARK: - Protocol

@MainActor
protocol ActivationPolicySetter {
    func setPolicy(_ policy: NSApplication.ActivationPolicy)
    func activate()
}

// MARK: - Default implementation

@MainActor
final class DefaultActivationPolicySetter: ActivationPolicySetter {
    func setPolicy(_ p: NSApplication.ActivationPolicy) { NSApp.setActivationPolicy(p) }
    func activate() { NSApp.activate() }
}

// MARK: - Coordinator

/// Counts dockworthy windows (those tagged with `dockworthyIdentifier`) and
/// flips `NSApp.activationPolicy` between `.accessory` (zero open) and
/// `.regular` (one or more open). HUD windows (recording pill, model download)
/// are intentionally untagged so they don't trigger the Dock icon.
@MainActor
final class WindowVisibilityCoordinator {
    static let dockworthyIdentifier = NSUserInterfaceItemIdentifier("voxline.dockworthy")

    private let center: NotificationCenter
    private let setter: ActivationPolicySetter
    private var trackedIDs: Set<ObjectIdentifier> = []
    private var observers: [NSObjectProtocol] = []

    /// - Parameters:
    ///   - center: The `NotificationCenter` to observe. Defaults to `.default`.
    ///             Inject a fresh instance in unit tests.
    ///   - setter: The activation-policy setter. Defaults to `nil`, which uses
    ///             `DefaultActivationPolicySetter` (calls `NSApp` directly).
    ///             Inject a stub in unit tests.
    init(
        center: NotificationCenter = .default,
        setter: ActivationPolicySetter? = nil
    ) {
        self.center = center
        self.setter = setter ?? DefaultActivationPolicySetter()
    }

    func start() {
        // Seed from windows that were already visible before we started observing.
        for w in NSApp.windows where isDockworthy(w) && w.isVisible {
            insert(w)
        }

        // didBecomeKeyNotification fires whenever a window becomes key — voxline's
        // user-facing windows all open via makeKeyAndOrderFront, so this catches
        // first-show. Re-keying an already-tracked window is a no-op thanks to
        // the Set-based idempotency in insert().
        let visibleObserver = center.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let w = note.object as? NSWindow else { return }
                if self.isDockworthy(w) { self.insert(w) }
            }
        }
        let closeObserver = center.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let w = note.object as? NSWindow else { return }
                self.remove(w)
            }
        }
        observers = [visibleObserver, closeObserver]
    }

    /// SwiftUI's `Settings` scene constructs its own `NSWindow` and may
    /// pre-create it before our snapshot, so we can't rely on
    /// "newly appeared." `NSApp.keyWindow` also doesn't work when the app
    /// is `.accessory`. Match permissively (any titled, visible, untagged
    /// window) and rely on the fact that other voxline windows are either
    /// pre-tagged dockworthy (About/Wizard/Debug) or borderless
    /// (recording pill).
    func tagSettingsWindowAfterOpen() {
        Task { @MainActor [weak self] in
            for delayMs in [60, 120, 200, 400, 800] {
                try? await Task.sleep(for: .milliseconds(delayMs))
                guard let self else { return }

                let candidate = NSApp.windows.first { w in
                    w.identifier != WindowVisibilityCoordinator.dockworthyIdentifier
                        && w.styleMask.contains(.titled)
                        && w.isVisible
                }
                if let w = candidate {
                    w.identifier = WindowVisibilityCoordinator.dockworthyIdentifier
                    self.insert(w)
                    return
                }
            }
        }
    }

    private func isDockworthy(_ w: NSWindow) -> Bool {
        w.identifier == WindowVisibilityCoordinator.dockworthyIdentifier
    }

    private func insert(_ w: NSWindow) {
        let id = ObjectIdentifier(w)
        let wasEmpty = trackedIDs.isEmpty
        let inserted = trackedIDs.insert(id).inserted
        if wasEmpty && inserted {
            setter.setPolicy(.regular)
            setter.activate()
        }
    }

    private func remove(_ w: NSWindow) {
        let id = ObjectIdentifier(w)
        let removed = trackedIDs.remove(id) != nil
        if removed && trackedIDs.isEmpty {
            setter.setPolicy(.accessory)
        }
    }

    deinit {
        for o in observers { center.removeObserver(o) }
    }
}
