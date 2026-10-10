import Testing
@testable import voxline

@Suite struct TapReconcileTests {

    private static let missing = AppStatus.permissionsError(TapReconcile.missingMessage)
    private static let revoked = AppStatus.permissionsError(TapReconcile.revokedMessage)

    // MARK: Install

    @Test func enabled_with_accessibility_installs_the_tap() {
        let decision = TapReconcile.decide(hotkeyEnabled: true, axGranted: true, isInstalled: false, status: .idle)
        #expect(decision == .init(tap: .install, status: nil))
    }

    @Test(arguments: [missing, revoked, .permissionsError("Text insertion needs Accessibility.")])
    func installing_the_tap_clears_a_permissions_banner(current: AppStatus) {
        let decision = TapReconcile.decide(hotkeyEnabled: true, axGranted: true, isInstalled: false, status: current)
        #expect(decision == .init(tap: .install, status: .idle))
    }

    @Test(arguments: [AppStatus.error("Transcription failed."), .preparingModel, .downloadingModel(progress: 0.4)])
    func installing_the_tap_leaves_every_other_status(current: AppStatus) {
        let decision = TapReconcile.decide(hotkeyEnabled: true, axGranted: true, isInstalled: false, status: current)
        #expect(decision == .init(tap: .install, status: nil))
    }

    // MARK: Uninstall

    @Test func losing_accessibility_while_enabled_removes_the_tap_and_says_so() {
        let decision = TapReconcile.decide(hotkeyEnabled: true, axGranted: false, isInstalled: true, status: .idle)
        #expect(decision == .init(tap: .uninstall, status: Self.revoked))
    }

    @Test(arguments: [true, false])
    func pausing_removes_the_tap_without_a_banner(axGranted: Bool) {
        let decision = TapReconcile.decide(hotkeyEnabled: false, axGranted: axGranted, isInstalled: true, status: .idle)
        #expect(decision == .init(tap: .uninstall, status: nil))
    }

    // MARK: Missing Accessibility

    /// Launch without Accessibility: model prep overwrites the banner and
    /// ends at idle, so the next tick puts it back. Same after resuming
    /// with Accessibility revoked while paused.
    @Test func enabled_without_accessibility_shows_the_missing_permission_once_idle() {
        let decision = TapReconcile.decide(hotkeyEnabled: true, axGranted: false, isInstalled: false, status: .idle)
        #expect(decision == .init(tap: .keep, status: Self.missing))
    }

    @Test(arguments: [missing, revoked, .preparingModel, .downloadingModel(progress: 0.4), .recording, .thinking, .error("Model setup failed.")])
    func enabled_without_accessibility_leaves_a_status_someone_else_set(current: AppStatus) {
        let decision = TapReconcile.decide(hotkeyEnabled: true, axGranted: false, isInstalled: false, status: current)
        #expect(decision == .init(tap: .keep, status: nil))
    }

    @Test func paused_without_accessibility_shows_no_banner() {
        let decision = TapReconcile.decide(hotkeyEnabled: false, axGranted: false, isInstalled: false, status: .idle)
        #expect(decision == .init(tap: .keep, status: nil))
    }

    // MARK: Settled

    @Test(arguments: [AppStatus.idle, .permissionsError("Text insertion needs Accessibility.")])
    func an_installed_tap_with_accessibility_changes_nothing(current: AppStatus) {
        let decision = TapReconcile.decide(hotkeyEnabled: true, axGranted: true, isInstalled: true, status: current)
        #expect(decision == .init(tap: .keep, status: nil))
    }

    @Test func paused_with_accessibility_and_no_tap_changes_nothing() {
        let decision = TapReconcile.decide(hotkeyEnabled: false, axGranted: true, isInstalled: false, status: .idle)
        #expect(decision == .init(tap: .keep, status: nil))
    }
}
