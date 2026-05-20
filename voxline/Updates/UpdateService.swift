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

extension UpdateService {
    /// Testable seam — independent of Sparkle types.
    /// Returns `false`: Sparkle should NOT use its modal UI for scheduled checks.
    func shouldSparkleHandleScheduledUpdateUI() -> Bool { false }

    /// Testable seam — true when the menu badge / "Install Update…" row
    /// is allowed to appear right now. (Once allowed, we set
    /// `hasPendingUpdate = true` and leave it there — the user dismisses
    /// it by clicking Install or by installing via Sparkle's modal.)
    func canSurfaceGentleReminder(now: Date = .now) -> Bool {
        !dictationActivity.isWithinDeferralWindow(now: now)
    }
}

extension UpdateService: SPUStandardUserDriverDelegate {

    /// Tell Sparkle we support gentle scheduled-update reminders.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Per-scheduled-check decision: should Sparkle itself drive the UI?
    /// We always answer "no" — voxline handles the presentation via the
    /// menu-bar badge, deferred around active dictation.
    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        shouldSparkleHandleScheduledUpdateUI()
    }

    /// Sparkle notifies us when it is about to (or just decided not to)
    /// present the standard UI for an update. We cache the item so a
    /// later menu-bar click can re-enter Sparkle's modal flow.
    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        if !handleShowingUpdate {
            pendingAppcastItem = update
            // Apply the deferral gate: only flip the visible badge once
            // dictation activity has settled. If we're inside the window,
            // poll back periodically until we can surface.
            tryRaisePendingFlag()
        }
    }

    /// Sparkle calls this once an update has been installed (or skipped
    /// permanently). Either way, our pending state is no longer valid.
    func standardUserDriverWillFinishUpdateSession() {
        pendingAppcastItem = nil
        hasPendingUpdate = false
    }
}

private extension UpdateService {
    func tryRaisePendingFlag() {
        if canSurfaceGentleReminder() {
            hasPendingUpdate = true
            return
        }
        // Try again in 30s. Cheap timer — the only state being polled is
        // a couple of Bool/Date reads.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            self?.tryRaisePendingFlag()
        }
    }
}
