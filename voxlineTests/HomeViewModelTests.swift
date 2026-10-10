import Foundation
import Testing
@testable import voxline

@Suite @MainActor struct HomeViewModelTests {

    private func makeStore() -> MeetingStore {
        MeetingStore(root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
    }

    private let granted = PermissionsSummary(microphone: .granted, accessibility: .granted, inputMonitoring: .granted)

    @Test func refresh_reads_meetings_from_the_store() throws {
        let store = makeStore()
        var older = try store.create(startedAt: Date(timeIntervalSince1970: 100), systemTapStarted: false)
        older.state = .done
        try store.save(older)
        var newer = try store.create(startedAt: Date(timeIntervalSince1970: 200), systemTapStarted: false)
        newer.state = .done
        try store.save(newer)

        let vm = HomeViewModel(state: AppState(), store: store, permissions: { self.granted }, fileExists: { _ in true })
        vm.refresh()
        #expect(vm.recentMeetings.map(\.id) == [newer.id, older.id])
    }

    @Test func meetings_section_hidden_without_a_meeting_controller() {
        let vm = HomeViewModel(state: AppState(), store: makeStore(), permissions: { self.granted }, fileExists: { _ in true })
        #expect(vm.showsMeetings == false)
    }

    @Test func refresh_permissions_reads_the_summary() {
        var summary = PermissionsSummary(microphone: .denied, accessibility: .granted, inputMonitoring: .granted)
        let vm = HomeViewModel(state: AppState(), store: makeStore(), permissions: { summary }, fileExists: { _ in true })
        vm.refreshPermissions()
        #expect(vm.permissions.requiredGranted == false)
        summary = granted
        vm.refreshPermissions()
        #expect(vm.permissions.requiredGranted == true)
    }

    /// The default folder is made only when the first notes are written, and
    /// opening a missing folder does nothing.
    @Test func opening_the_meetings_folder_creates_it_first() {
        let parent = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: parent) }
        let folder = parent.appending(path: "voxline Meetings")
        var opened: URL?
        let vm = HomeViewModel(
            state: AppState(),
            store: makeStore(),
            permissions: { self.granted },
            fileExists: { _ in true },
            meetingsFolder: { folder },
            openInFinder: { opened = $0 }
        )

        vm.openMeetingsFolder()

        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        #expect(opened == folder)
    }
}
