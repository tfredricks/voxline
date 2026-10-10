import AppKit
import Observation

@Observable
@MainActor
final class HomeViewModel {
    let state: AppState
    private(set) var permissions: PermissionsSummary
    private(set) var recentMeetings: [RecentMeeting] = []

    @ObservationIgnored private let store: MeetingStore?
    @ObservationIgnored private let readPermissions: () -> PermissionsSummary
    @ObservationIgnored private let fileExists: (URL) -> Bool
    @ObservationIgnored private let meetingsFolder: () -> URL
    @ObservationIgnored private let openInFinder: (URL) -> Void

    init(
        state: AppState,
        store: MeetingStore? = try? MeetingStore.standard(),
        permissions: @escaping () -> PermissionsSummary = { PermissionsService().summary() },
        fileExists: @escaping (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
        meetingsFolder: @escaping () -> URL = { AppSettings().meetingNotesFolder },
        openInFinder: @escaping (URL) -> Void = { _ = NSWorkspace.shared.open($0) }
    ) {
        self.state = state
        self.store = store
        self.readPermissions = permissions
        self.fileExists = fileExists
        self.meetingsFolder = meetingsFolder
        self.openInFinder = openInFinder
        self.permissions = permissions()
    }

    var showsMeetings: Bool { state.meetings != nil }

    func refresh() {
        refreshPermissions()
        recentMeetings = RecentMeetings.rows(
            metas: store?.all() ?? [],
            phase: state.meetings?.phase ?? .idle,
            fileExists: fileExists
        )
    }

    func refreshPermissions() {
        let latest = readPermissions()
        if latest != permissions { permissions = latest }
    }

    /// Opens the meeting notes folder, creating it first: it is otherwise
    /// made only when the first notes are written, and opening a missing
    /// folder does nothing.
    func openMeetingsFolder() {
        let folder = meetingsFolder()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            AppLog.meetings.error("meetings folder unavailable: \(error.localizedDescription, privacy: .public)")
        }
        openInFinder(folder)
    }
}
