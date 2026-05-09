import Foundation

/// Maps AppStatus → SF Symbol name for the menu bar icon.
enum MenuBarIcon {
    static func symbolName(for status: AppStatus) -> String {
        switch status {
        case .idle:             return "mic"
        case .recording:        return "mic.fill"
        case .thinking:         return "ellipsis.circle"
        case .downloadingModel: return "arrow.down.circle"
        case .error:            return "mic.slash"
        }
    }
}
