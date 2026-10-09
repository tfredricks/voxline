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
}
