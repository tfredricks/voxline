import AppKit

/// Keeps `NSApp.activationPolicy()` equal to `DockPolicy` for the windows on
/// screen right now. Nothing is tracked between events, and the policy is
/// set only when it changes: a redundant `.regular` interrupts AppKit's
/// in-flight activation and flickers the window being shown. A flip to
/// `.regular` caused by a window event also activates the app, whichever
/// window event arrives first; the Show in Dock toggle and the launch-time
/// evaluation never activate.
@MainActor
final class ActivationPolicyController {
    private let center: NotificationCenter
    private let showInDock: () -> Bool
    private var observers: [NSObjectProtocol] = []

    init(center: NotificationCenter = .default, showInDock: @escaping () -> Bool = { AppSettings().showInDock }) {
        self.center = center
        self.showInDock = showInDock
    }

    func start() {
        observe(NSWindow.didBecomeKeyNotification) { $0.reevaluate(activating: true) }
        observe(NSWindow.didMiniaturizeNotification) { $0.reevaluate(activating: true) }
        observe(NSWindow.didDeminiaturizeNotification) { $0.reevaluate(activating: true) }
        observe(NSWindow.didChangeOcclusionStateNotification) { $0.reevaluate(activating: true) }
        observe(UserDefaults.didChangeNotification) { $0.reevaluate(activating: false) }
        observe(NSWindow.willCloseNotification) { controller in
            DispatchQueue.main.async { [weak controller] in controller?.reevaluate(activating: true) }
        }
        reevaluate(activating: false)
    }

    private func observe(_ name: Notification.Name, _ handler: @escaping @MainActor (ActivationPolicyController) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                handler(self)
            }
        }
        observers.append(token)
    }

    private func reevaluate(activating: Bool) {
        let target = DockPolicy.policy(showInDock: showInDock(), windows: NSApp.windows.map(WindowSnapshot.init))
        guard target != NSApp.activationPolicy() else { return }
        NSApp.setActivationPolicy(target)
        if target == .regular && activating {
            NSApp.activate()
        }
    }

    deinit {
        for o in observers { center.removeObserver(o) }
    }
}
