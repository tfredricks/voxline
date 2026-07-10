import Foundation

/// Maps AppStatus → SF Symbol name for the menu bar icon.
enum MenuBarIcon {
    static func symbolName(for status: AppStatus, paused: Bool = false) -> String {
        // Active status wins over paused — recording/error/downloading are
        // more urgent signals and pause is a future-only effect anyway.
        switch status {
        case .recording:        return "mic.fill"
        case .thinking:         return "ellipsis.circle"
        case .downloadingModel: return "arrow.down.circle"
        case .preparingModel:   return "gearshape.circle"
        // A permissions problem is distinct from a generic mic/pipeline error:
        // it's user-fixable in System Settings, so it gets its own warning
        // badge rather than sharing the mic.slash symbol.
        case .permissionsError: return "exclamationmark.triangle.fill"
        case .error:            return "mic.slash"
        case .idle:             return paused ? "pause.circle" : "mic"
        }
    }
}
