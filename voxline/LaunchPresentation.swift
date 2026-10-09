import Foundation

/// What the app shows by itself at launch.
enum LaunchPresentation: Equatable {
    case wizard, home, none

    static func decide(firstRunComplete: Bool, requiredPermissionsGranted: Bool, launchedAtLogin: Bool) -> LaunchPresentation {
        guard firstRunComplete else { return .wizard }
        guard requiredPermissionsGranted else { return .home }
        return launchedAtLogin ? .none : .home
    }
}

enum LoginLaunch {
    /// A launch counts as "at login" when macOS says so, or when it happened
    /// within `window` seconds of the console session starting.
    static func isLoginLaunch(appleEventSaysLogin: Bool, sessionStart: Date?, launchedAt: Date, window: TimeInterval = 60) -> Bool {
        if appleEventSaysLogin { return true }
        guard let sessionStart else { return false }
        let elapsed = launchedAt.timeIntervalSince(sessionStart)
        return elapsed >= 0 && elapsed <= window
    }
}
