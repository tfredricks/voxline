import AppKit
import SwiftUI

struct MenuBarContent: View {
    @Bindable var state: AppState
    @Bindable var updateService: UpdateService

    var openAboutWindow: () -> Void = {}
    var openHistoryWindow: () -> Void = {}
    var openMainWindow: (MainWindowPage) -> Void = { _ in }
    var retryLastDictation: () -> Void = {}
    var startMeetingRecording: () -> Void = {}

    var body: some View {
        Button("Open Voxline") { openMainWindow(.home) }
            .keyboardShortcut("o")

        Divider()

        if let message = state.status.errorMessage {
            Text(message)
                .foregroundStyle(.red)
            if case .permissionsError = state.status {
                Button("Fix permissions…") { openMainWindow(.home) }
            }
            Divider()
        }

        if case .downloadingModel(let p) = state.status {
            Text("Downloading model — \(Int(p * 100))%")
                .foregroundStyle(.secondary)
            Divider()
        }

        if updateService.hasPendingUpdate {
            Button("Install update…") {
                updateService.checkForUpdates()
            }
            Divider()
        }

        Button(state.hotkeyEnabled ? "Pause Voxline" : "Resume Voxline") {
            state.hotkeyEnabled.toggle()
        }

        Divider()

        Button("Retry last dictation") { retryLastDictation() }
            .disabled(!state.canRetryLastDictation)

        Button("Show history…") { openHistoryWindow() }

        Divider()

        if let meetings = state.meetings {
            switch meetings.phase {
            case .idle:
                Button("Start Meeting Recording") { startMeetingRecording() }
            case .recording(let startedAt):
                Button("Stop Meeting Recording") { meetings.stop() }
                Text("Recording since \(startedAt.formatted(date: .omitted, time: .shortened))")
                    .foregroundStyle(.secondary)
            case .processing(let stage):
                Text(stage?.label ?? "Processing meeting…")
                    .foregroundStyle(.secondary)
            }
            if meetings.lastFailedMeeting != nil {
                Button("Retry Processing") { meetings.retryFailed() }
                    .disabled(meetings.phase != .idle)
            }
            let recent = meetings.regenerableMeetings
            if !recent.isEmpty {
                Menu("Regenerate Notes") {
                    ForEach(recent, id: \.id) { meta in
                        Button("\(meta.startedAt.formatted(date: .abbreviated, time: .shortened)) — \(meta.title ?? MeetingMarkdown.untitled)") {
                            meetings.regenerate(meta.id)
                        }
                    }
                }
                .disabled(meetings.phase != .idle)
            }
            Divider()
        }

        Button("Settings…") { openMainWindow(.general) }
            .keyboardShortcut(",")

        Divider()

        Button("Check for updates…") {
            updateService.checkForUpdates()
        }

        Button("About Voxline") { openAboutWindow() }

        Divider()

        Button("Quit Voxline") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
