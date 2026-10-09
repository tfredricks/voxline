import Foundation
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

    init(
        state: AppState,
        store: MeetingStore? = try? MeetingStore.standard(),
        permissions: @escaping () -> PermissionsSummary = { PermissionsService().summary() },
        fileExists: @escaping (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) {
        self.state = state
        self.store = store
        self.readPermissions = permissions
        self.fileExists = fileExists
        self.permissions = permissions()
    }

    var showsMeetings: Bool { state.meetings != nil }

    func refresh() {
        refreshPermissions()
        recentMeetings = RecentMeetings.rows(
            metas: store?.all() ?? [],
            phase: state.meetings?.phase ?? .idle,
            lastFailed: state.meetings?.lastFailedMeeting,
            fileExists: fileExists
        )
    }

    func refreshPermissions() {
        let latest = readPermissions()
        if latest != permissions { permissions = latest }
    }
}
