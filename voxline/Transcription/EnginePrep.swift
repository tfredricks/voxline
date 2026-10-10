import Foundation

/// How the coordinator brings an engine to ready, decided from its readiness.
enum EnginePrep {
    enum Plan: Equatable {
        /// Already usable; `prepare` only warms it (WhisperKit's compile).
        case warm
        /// Needs a download or asset install, shown with progress.
        case download
        /// Can't run; the associated value is the user-facing reason.
        case fail(String)
    }

    static func plan(for readiness: EngineReadiness) -> Plan {
        switch readiness {
        case .ready:                   return .warm
        case .needsPreparation:        return .download
        case .unavailable(let reason): return .fail(reason)
        }
    }

    /// Who a prepare task reports to.
    enum Audience: Equatable {
        /// Launch, or a switch that takes its place: owns `AppState.status`
        /// from the start and shows the download window.
        case launch
        /// The first-run wizard and its Retry: owns the status from the
        /// start, never shows the window (the wizard's speech-engine step
        /// shows the progress).
        case wizard
        /// A settings switch replacing a task that was driving the status:
        /// owns the status from the start, never shows the window.
        case inheritedStatus
        /// A settings switch after launch: reports only a download or a
        /// failure, and only from an idle or error status. A warm-up is silent.
        case settingsSwitch

        /// The audience for a settings switch, given what the in-flight
        /// prepare task (if any) owns. Taking over what it owned keeps the
        /// status from freezing at the cancelled task's value.
        static func forSwitch(inFlightOwnsLaunchUI: Bool, inFlightDrivesStatus: Bool) -> Audience {
            if inFlightOwnsLaunchUI { return .launch }
            if inFlightDrivesStatus { return .inheritedStatus }
            return .settingsSwitch
        }

        /// Whether the task sets a provisional `.preparingModel` before
        /// readiness is known.
        var ownsStatusFromStart: Bool { self != .settingsSwitch }
    }

    /// The status a prepare task sets once its plan is known, or nil to
    /// leave the status alone and stay silent for the rest of the task.
    static func status(for plan: Plan, audience: Audience, current: AppStatus) -> AppStatus? {
        let canReport: Bool
        switch audience {
        case .launch, .wizard, .inheritedStatus:
            canReport = current.blocksRecording
        case .settingsSwitch:
            switch (plan, current) {
            case (.warm, _):              canReport = false
            case (_, .idle), (_, .error): canReport = true
            default:                      canReport = false
            }
        }
        guard canReport else { return nil }
        switch plan {
        case .warm:             return .preparingModel
        case .download:         return .downloadingModel(progress: 0)
        case .fail(let reason): return .error(reason)
        }
    }

    /// Whether a prepare task may still touch the status and the download
    /// window: no newer task has started and it hasn't been cancelled. A
    /// cancelled download can surface as an ordinary error (WhisperKit's Hub
    /// download throws `URLError(.cancelled)`), so its handler checks this
    /// before reporting.
    static func isCurrentTask(token: UInt64, latestToken: UInt64, isCancelled: Bool) -> Bool {
        !isCancelled && token == latestToken
    }

    static func showsDownloadWindow(for plan: Plan, audience: Audience) -> Bool {
        audience == .launch && plan == .download
    }

    /// Whether saving or clearing the OpenAI key calls for re-checking the
    /// selected engine's readiness.
    static func rechecksAfterOpenAIKeyChange(selected: EngineID) -> Bool {
        selected == .openAIRealtime
    }

    /// Whether `status` is an OpenAI key error (missing, or unreadable from
    /// the keychain), which a re-check replaces. It is cleared before the
    /// re-check, so a saved key leaves the status idle; a key that is still
    /// unusable gets the error back from the re-check.
    static func isOpenAIKeyError(_ status: AppStatus) -> Bool {
        status == .error(OpenAIRealtimeEngine.missingKeyReason)
            || status == .error(OpenAIRealtimeEngine.keychainReadFailedReason)
    }

    /// Whether a prepare task resets `current` to idle once its plan is known.
    /// A warm plan means the selected engine runs, so an error a previous
    /// prepare task wrote (`lastPrepError`) is stale, and so is an OpenAI key
    /// error, which the pipeline and a key change write too. A
    /// settings switch warms silently and would otherwise leave them showing.
    /// Every other status stays: a pipeline error keeps the pill's Retry.
    static func clearsStaleError(plan: Plan, current: AppStatus, lastPrepError: String?) -> Bool {
        guard plan == .warm, case .error(let message) = current else { return false }
        return message == lastPrepError || isOpenAIKeyError(current)
    }

    /// The error a prepare task wrote, while `current` still shows it; nil
    /// once the status has moved on, so the same text written later by
    /// someone else isn't taken for it.
    static func prepErrorStillShowing(_ last: String?, current: AppStatus?) -> String? {
        guard let last, current == .error(last) else { return nil }
        return last
    }
}
