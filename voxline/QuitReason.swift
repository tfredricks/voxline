import CoreServices
import Foundation

/// Why macOS asked voxline to quit, from the quit Apple Event's
/// `kAEQuitReason`.
enum QuitReason {
    /// Whether the quit is part of a logout, restart, or shutdown. An alert
    /// then holds up loginwindow, which gives up and cancels the logout.
    static func endsSession(_ reason: OSType?) -> Bool {
        guard let reason else { return false }
        return sessionEndReasons.contains(reason)
    }

    /// The reason on the Apple Event being handled, or nil when the quit
    /// didn't come from one (Quit Voxline in the menu bar).
    @MainActor static var current: OSType? {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return nil }
        let keyword = AEKeyword(kAEQuitReason)
        let descriptor = event.attributeDescriptor(forKeyword: keyword) ?? event.paramDescriptor(forKeyword: keyword)
        return descriptor?.typeCodeValue
    }

    private static let sessionEndReasons: Set<OSType> = Set(
        [kAELogOut, kAEReallyLogOut, kAEShowRestartDialog, kAERestart, kAEShowShutdownDialog, kAEShutDown].map { OSType($0) }
    )
}
