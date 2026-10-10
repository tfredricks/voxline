import Foundation

/// One tick of the coordinator's reconcile loop: whether the hotkey tap goes
/// in or out, and the status that tells the user Accessibility is missing.
enum TapReconcile {
    enum TapChange: Equatable {
        case install, uninstall, keep
    }

    struct Decision: Equatable {
        var tap: TapChange
        /// Set once the tap change is made. A failed install sets nothing and
        /// is retried on the next tick.
        var status: AppStatus?
    }

    static let missingMessage = "Hotkey monitoring requires Accessibility permission. Grant it in System Settings → Privacy & Security — Voxline will pick it up automatically."
    static let revokedMessage = "Accessibility permission was revoked. Re-grant it in System Settings → Privacy & Security; Voxline will recover automatically."

    /// The tap is wanted while the hotkey is enabled and Accessibility is
    /// granted; Input Monitoring alone never installs it. Installing it clears
    /// a permissions banner, and losing Accessibility while enabled removes it
    /// with the revoked banner. While enabled without Accessibility, an idle
    /// status gets the missing banner back, so a status written meanwhile
    /// (model prep at launch ends at idle) can't leave it reading "Ready".
    /// Paused, there is no banner.
    static func decide(hotkeyEnabled: Bool, axGranted: Bool, isInstalled: Bool, status: AppStatus) -> Decision {
        let wanted = hotkeyEnabled && axGranted
        if wanted && !isInstalled {
            return Decision(tap: .install, status: isPermissionsError(status) ? .idle : nil)
        }
        if !wanted && isInstalled {
            return Decision(tap: .uninstall, status: hotkeyEnabled ? .permissionsError(revokedMessage) : nil)
        }
        if hotkeyEnabled && !axGranted && status == .idle {
            return Decision(tap: .keep, status: .permissionsError(missingMessage))
        }
        return Decision(tap: .keep, status: nil)
    }

    private static func isPermissionsError(_ status: AppStatus) -> Bool {
        if case .permissionsError = status { return true }
        return false
    }
}
