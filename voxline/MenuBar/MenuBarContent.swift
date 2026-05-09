// voxline/MenuBar/MenuBarContent.swift  (replace contents)
import SwiftUI

struct MenuBarContent: View {
    @Bindable var state: AppState
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if case .error(let message) = state.status {
            Text(message)
                .foregroundStyle(.red)
            Divider()
        }

        if case .downloadingModel(let p) = state.status {
            Text("Downloading model — \(Int(p * 100))%")
                .foregroundStyle(.secondary)
            Divider()
        }

        Button("Settings…") {
            openSettings()
            NSApp.activate()
        }
        .keyboardShortcut(",")

        Divider()

        Menu("Debug") {
            Text("Status: \(statusLabel)")
            Text("Hotkey state: \(state.debugHotkeyState)")
            Text("Tap installed: \(state.debugTapInstalled ? "yes" : "no")")
            Text("Pipeline phase: \(state.debugPipelinePhase)")
            if let started = state.recordingStartedAt {
                Text("Recording started: \(started.formatted(date: .omitted, time: .standard))")
            }
            if let last = state.lastTranscript, !last.isEmpty {
                Divider()
                Text("Last transcript:")
                Text(last.prefix(200).description)
                    .foregroundStyle(.secondary)
            }
        }

        Divider()

        Button("Quit voxline") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private var statusLabel: String {
        switch state.status {
        case .idle: return "idle"
        case .recording: return "recording"
        case .thinking: return "thinking"
        case .preparingModel: return "preparingModel"
        case .downloadingModel(let p): return "downloadingModel(\(Int(p * 100))%)"
        case .error(let msg): return "error: \(msg.prefix(80))"
        }
    }
}
