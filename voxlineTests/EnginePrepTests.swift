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

    // MARK: OpenAI key change

    @Test func an_openai_key_change_rechecks_only_the_openai_engine() {
        #expect(EnginePrep.rechecksAfterOpenAIKeyChange(selected: .openAIRealtime))
        #expect(!EnginePrep.rechecksAfterOpenAIKeyChange(selected: .whisperKit))
        #expect(!EnginePrep.rechecksAfterOpenAIKeyChange(selected: .apple))
    }

    @Test func only_the_missing_key_error_is_cleared_before_the_recheck() {
        #expect(EnginePrep.isMissingOpenAIKeyError(.error(OpenAIRealtimeEngine.missingKeyReason)))
        #expect(!EnginePrep.isMissingOpenAIKeyError(.error("Transcription failed. Try again or pick a different engine in Settings → General.")))
        #expect(!EnginePrep.isMissingOpenAIKeyError(.idle))
        #expect(!EnginePrep.isMissingOpenAIKeyError(.thinking))
    }

    // MARK: Stale engine error

    private static let pipelineError = "Transcription failed. Try again or pick a different engine in Settings → General."
    private static let setupFailed = "Model setup failed: The Internet connection appears to be offline.. Try Retry or relaunch Voxline."

    /// Switching from OpenAI without a key to an engine that only needs
    /// warming is silent, so without the clear the old error would stay.
    /// The pipeline and a key change write this error too, so it is cleared
    /// whoever wrote it.
    @Test(arguments: [nil, setupFailed])
    func a_warm_plan_clears_the_missing_key_error(lastPrepError: String?) {
        #expect(EnginePrep.clearsStaleError(plan: .warm, current: .error(OpenAIRealtimeEngine.missingKeyReason), lastPrepError: lastPrepError))
    }

    /// An offline launch with an uncached Whisper model, then a switch to
    /// Apple Speech; or Apple Speech on an unsupported language, then a
    /// switch to Whisper.
    @Test(arguments: [setupFailed, reason])
    func a_warm_plan_clears_the_error_the_last_prep_wrote(message: String) {
        #expect(EnginePrep.clearsStaleError(plan: .warm, current: .error(message), lastPrepError: message))
    }

    /// A pipeline error keeps the pill's Retry, so a switch never clears it.
    @Test(arguments: [nil, setupFailed])
    func a_warm_plan_keeps_a_pipeline_error(lastPrepError: String?) {
        #expect(!EnginePrep.clearsStaleError(plan: .warm, current: .error(Self.pipelineError), lastPrepError: lastPrepError))
    }

    /// An engine's reason that no prep task wrote (the pipeline showed it).
    @Test func a_warm_plan_keeps_an_error_no_prep_wrote() {
        #expect(!EnginePrep.clearsStaleError(plan: .warm, current: .error(Self.reason), lastPrepError: nil))
    }

    @Test(arguments: [AppStatus.permissionsError(setupFailed), .idle, .thinking, .recording])
    func a_warm_plan_keeps_every_other_status(current: AppStatus) {
        #expect(!EnginePrep.clearsStaleError(plan: .warm, current: current, lastPrepError: Self.setupFailed))
    }

    /// A download or a failure reports its own status over the error.
    @Test func only_a_warm_plan_clears_a_stale_error() {
        let missingKey = AppStatus.error(OpenAIRealtimeEngine.missingKeyReason)
        #expect(!EnginePrep.clearsStaleError(plan: .download, current: missingKey, lastPrepError: nil))
        #expect(!EnginePrep.clearsStaleError(plan: .fail(OpenAIRealtimeEngine.missingKeyReason), current: missingKey, lastPrepError: nil))
        #expect(!EnginePrep.clearsStaleError(plan: .fail(Self.reason), current: missingKey, lastPrepError: nil))
        #expect(!EnginePrep.clearsStaleError(plan: .download, current: .error(Self.setupFailed), lastPrepError: Self.setupFailed))
        #expect(!EnginePrep.clearsStaleError(plan: .fail(Self.reason), current: .error(Self.setupFailed), lastPrepError: Self.setupFailed))
    }

    // MARK: Remembered prep error

    @Test func the_prep_error_is_remembered_while_it_shows() {
        #expect(EnginePrep.prepErrorStillShowing(Self.setupFailed, current: .error(Self.setupFailed)) == Self.setupFailed)
    }

    /// Once the status moved on, the same text written later by someone
    /// else isn't the prep's error.
    @Test(arguments: [AppStatus.idle, .recording, .thinking, .preparingModel, .error(pipelineError), .permissionsError(setupFailed)])
    func the_prep_error_is_forgotten_once_the_status_moves_on(current: AppStatus) {
        #expect(EnginePrep.prepErrorStillShowing(Self.setupFailed, current: current) == nil)
    }

    @Test func no_prep_error_stays_none() {
        #expect(EnginePrep.prepErrorStillShowing(nil, current: .error(Self.setupFailed)) == nil)
    }

    @Test func the_prep_error_is_forgotten_without_a_state() {
        #expect(EnginePrep.prepErrorStillShowing(Self.setupFailed, current: nil) == nil)
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
