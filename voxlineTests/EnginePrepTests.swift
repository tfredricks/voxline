import Testing
@testable import voxline

@Suite struct EnginePrepTests {

    private static let reason = "Apple Speech doesn't support this Mac's language."

    // MARK: Plan

    @Test func ready_engine_is_warmed() {
        #expect(EnginePrep.plan(for: .ready) == .warm)
    }

    @Test(arguments: [Optional(1_500), nil])
    func engine_needing_preparation_is_downloaded(downloadMB: Int?) {
        #expect(EnginePrep.plan(for: .needsPreparation(downloadMB: downloadMB)) == .download)
    }

    @Test func unavailable_engine_fails_with_its_reason() {
        #expect(EnginePrep.plan(for: .unavailable(Self.reason)) == .fail(Self.reason))
    }

    // MARK: Audience for a settings switch

    @Test func switch_during_launch_prep_takes_over_the_launch_ui() {
        #expect(EnginePrep.Audience.forSwitch(inFlightOwnsLaunchUI: true, inFlightDrivesStatus: true) == .launch)
    }

    @Test func switch_during_a_status_driving_prep_takes_over_the_status() {
        #expect(EnginePrep.Audience.forSwitch(inFlightOwnsLaunchUI: false, inFlightDrivesStatus: true) == .inheritedStatus)
    }

    @Test func switch_with_no_status_owner_is_a_plain_settings_switch() {
        #expect(EnginePrep.Audience.forSwitch(inFlightOwnsLaunchUI: false, inFlightDrivesStatus: false) == .settingsSwitch)
    }

    @Test func provisional_status_is_set_only_by_status_owners() {
        #expect(EnginePrep.Audience.launch.ownsStatusFromStart)
        #expect(EnginePrep.Audience.inheritedStatus.ownsStatusFromStart)
        #expect(!EnginePrep.Audience.settingsSwitch.ownsStatusFromStart)
    }

    // MARK: Status path

    @Test(arguments: [EnginePrep.Audience.launch, .inheritedStatus])
    func status_owners_report_every_plan(audience: EnginePrep.Audience) {
        #expect(EnginePrep.status(for: .warm, audience: audience, current: .preparingModel) == .preparingModel)
        #expect(EnginePrep.status(for: .download, audience: audience, current: .preparingModel) == .downloadingModel(progress: 0))
        #expect(EnginePrep.status(for: .fail(Self.reason), audience: audience, current: .preparingModel) == .error(Self.reason))
    }

    @Test(arguments: [EnginePrep.Audience.launch, .inheritedStatus])
    func status_owners_yield_to_a_status_someone_else_set(audience: EnginePrep.Audience) {
        let permissions = AppStatus.permissionsError("Grant Accessibility.")
        #expect(EnginePrep.status(for: .download, audience: audience, current: permissions) == nil)
        #expect(EnginePrep.status(for: .warm, audience: audience, current: permissions) == nil)
    }

    @Test(arguments: [AppStatus.idle, .error("Previous failure.")])
    func settings_switch_reports_a_download_but_warms_silently(current: AppStatus) {
        #expect(EnginePrep.status(for: .warm, audience: .settingsSwitch, current: current) == nil)
        #expect(EnginePrep.status(for: .download, audience: .settingsSwitch, current: current) == .downloadingModel(progress: 0))
        #expect(EnginePrep.status(for: .fail(Self.reason), audience: .settingsSwitch, current: current) == .error(Self.reason))
    }

    @Test(arguments: [AppStatus.recording, .thinking, .permissionsError("Grant Accessibility.")])
    func settings_switch_never_interrupts_a_busy_status(current: AppStatus) {
        #expect(EnginePrep.status(for: .download, audience: .settingsSwitch, current: current) == nil)
        #expect(EnginePrep.status(for: .fail(Self.reason), audience: .settingsSwitch, current: current) == nil)
    }

    // MARK: Superseded tasks

    @Test func the_latest_uncancelled_task_owns_status_and_window() {
        #expect(EnginePrep.isCurrentTask(token: 3, latestToken: 3, isCancelled: false))
    }

    @Test func a_cancelled_task_no_longer_owns_them() {
        #expect(!EnginePrep.isCurrentTask(token: 3, latestToken: 3, isCancelled: true))
    }

    @Test func a_superseded_task_no_longer_owns_them_even_if_not_yet_cancelled() {
        #expect(!EnginePrep.isCurrentTask(token: 2, latestToken: 3, isCancelled: false))
        #expect(!EnginePrep.isCurrentTask(token: 2, latestToken: 3, isCancelled: true))
    }

    // MARK: Download window

    @Test func only_the_launch_audience_shows_the_download_window_and_only_to_download() {
        #expect(EnginePrep.showsDownloadWindow(for: .download, audience: .launch))
        #expect(!EnginePrep.showsDownloadWindow(for: .warm, audience: .launch))
        #expect(!EnginePrep.showsDownloadWindow(for: .fail(Self.reason), audience: .launch))
        #expect(!EnginePrep.showsDownloadWindow(for: .download, audience: .inheritedStatus))
        #expect(!EnginePrep.showsDownloadWindow(for: .download, audience: .settingsSwitch))
    }
}
