// voxline/Settings/RunningAppsHelper.swift
import AppKit

struct RunningAppEntry: Identifiable, Equatable {
    var id: String { bundleID }
    let bundleID: String
    let displayName: String

    static func == (lhs: RunningAppEntry, rhs: RunningAppEntry) -> Bool {
        lhs.bundleID == rhs.bundleID && lhs.displayName == rhs.displayName
    }
}

enum RunningAppsHelper {
    /// Snapshot of currently running, regular-activation apps with a bundle ID.
    /// Sorted by display name, case-insensitive. Excludes voxline itself.
    static func snapshot() -> [RunningAppEntry] {
        let me = Bundle.main.bundleIdentifier
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> RunningAppEntry? in
                guard let bundleID = app.bundleIdentifier, bundleID != me else { return nil }
                let name = app.localizedName ?? bundleID
                return RunningAppEntry(bundleID: bundleID, displayName: name)
            }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }
}
