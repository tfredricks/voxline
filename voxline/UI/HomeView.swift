import AppKit
import Combine
import SwiftUI

struct HomeView: View {
    @Bindable var model: HomeViewModel
    let issues: [SetupIssue]
    let open: (MainWindowPage) -> Void
    @Environment(UpdateService.self) private var updateService
    @State private var showsPermissionDetails = false

    private let permissionTick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section { statusRow }
            if !issues.isEmpty {
                Section("Setup") {
                    ForEach(issues) { issue in
                        HStack {
                            Label {
                                Text(issue.text)
                            } icon: {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .foregroundStyle(.orange)
                            }
                            Spacer()
                            Button("Open \(issue.page.title)") { open(issue.page) }
                        }
                    }
                }
            }
            Section("Permissions") { permissions }
            if model.showsMeetings {
                Section("Recent meetings") { meetings }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Home")
        .onAppear { model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in model.refresh() }
        .onReceive(permissionTick) { _ in model.refreshPermissions() }
        .onChange(of: model.state.meetings?.phase) { model.refresh() }
    }

    private var statusRow: some View {
        let state = model.state
        let meetingRecording = state.meetings?.phase.isRecording ?? false
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: MenuBarIcon.symbolName(for: state.status, paused: !state.hotkeyEnabled, meetingRecording: meetingRecording))
                    .font(.title2)
                    .frame(width: 28)
                Text(HomeStatus.text(for: state.status, paused: !state.hotkeyEnabled, meetingRecording: meetingRecording))
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(state.hotkeyEnabled ? "Pause" : "Resume") { state.hotkeyEnabled.toggle() }
            }
            if updateService.hasPendingUpdate {
                Button("Update available — Install") { updateService.checkForUpdates() }
                    .buttonStyle(.link)
            }
        }
    }

    @ViewBuilder
    private var permissions: some View {
        if model.permissions.requiredGranted && !showsPermissionDetails {
            HStack {
                Label("All required permissions granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Spacer()
                Button("Show details") { showsPermissionDetails = true }
                    .buttonStyle(.link)
            }
        } else {
            PermissionRows(summary: model.permissions, onChange: { model.refreshPermissions() })
        }
    }

    @ViewBuilder
    private var meetings: some View {
        if model.recentMeetings.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("No meetings yet")
                if let shortcut = AppSettings().meetingShortcut {
                    Text("Start one from the menu bar or with \(shortcut.displayName).")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            ForEach(model.recentMeetings) { meeting in
                meetingRow(meeting)
            }
        }
        Button("Open meetings folder") { model.openMeetingsFolder() }
    }

    @ViewBuilder
    private func meetingRow(_ meeting: RecentMeeting) -> some View {
        if meeting.notesURL != nil {
            meetingRowContent(meeting).help("Open notes")
        } else {
            meetingRowContent(meeting)
        }
    }

    private func meetingRowContent(_ meeting: RecentMeeting) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.title)
                Text(meeting.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let stage = meeting.stageLabel {
                Text(stage).foregroundStyle(.secondary)
            } else {
                Text(Duration.seconds(meeting.durationSeconds).formatted(.time(pattern: .hourMinute)))
                    .foregroundStyle(.secondary)
            }
            if meeting.showsRetry {
                Button("Retry") { model.state.meetings?.retryFailed() }
                    .disabled(model.state.meetings?.phase != .idle)
            }
            if meeting.notesURL == nil && meeting.stageLabel == nil {
                Text("Notes not available").font(.callout).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if let url = meeting.notesURL { NSWorkspace.shared.open(url) }
        }
    }
}
