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
        /// Launch, wizard retry, or a switch that takes their place: owns
        /// `AppState.status` from the start and shows the download window.
        case launch
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
        case .launch, .inheritedStatus:
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

    static func showsDownloadWindow(for plan: Plan, audience: Audience) -> Bool {
        audience == .launch && plan == .download
    }
}
