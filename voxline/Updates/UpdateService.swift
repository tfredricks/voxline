import AppKit
import Foundation
import Observation
import Sparkle

/// Thin wrapper around Sparkle's `SPUStandardUpdaterController`.
///
/// Owns the updater for the app's lifetime, surfaces a small Observable
/// API for SwiftUI bindings, and bridges Sparkle activity into voxline's
/// existing log pipeline.
@Observable
@MainActor
final class UpdateService: NSObject {

    /// Reflects whether a pending update has been deferred from the
    /// scheduled (gentle) path. Drives the menu-bar badge and the
    /// "Install Update…" row.
    private(set) var hasPendingUpdate: Bool = false

    var automaticallyChecksForUpdates: Bool {
        get { updaterController.updater.automaticallyChecksForUpdates }
        set { updaterController.updater.automaticallyChecksForUpdates = newValue }
    }

    private let dictationActivity: DictationActivityMonitor

    /// Cached most-recent appcast item Sparkle wants to show on the
    /// scheduled path, used so a menu click can re-enter Sparkle's modal.
    fileprivate var pendingAppcastItem: SUAppcastItem?

    private var updaterController: SPUStandardUpdaterController!

    init(dictationActivity: DictationActivityMonitor) {
        self.dictationActivity = dictationActivity
        super.init()
        // Delegate references are set after super.init(), so construct the
        // controller here once self is fully initialised.
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: self
        )
    }

    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }
}

extension UpdateService: SPUUpdaterDelegate {
    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        AppLog.updates.error("update check aborted: \(error.localizedDescription)")
    }
}

// Gentle-reminders delegate methods land in Task 5.
extension UpdateService: SPUStandardUserDriverDelegate {}
