// voxline/MenuBar/MenuBarContent.swift  (replace contents)
import AppKit
import SwiftUI

struct MenuBarContent: View {
    @Bindable var state: AppState
    @Environment(\.openSettings) private var openSettings

    /// Closure invoked by the "Open Debug Window…" menu item.
    /// Wired in voxlineApp via the AppDelegate's DebugWindowController.
    var openDebugWindow: () -> Void = {}

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
            Text("Mic: \(state.debugMicrophoneStatus)")
            Text("Accessibility: \(state.debugAccessibilityStatus)")
            Text("Input Monitoring: \(state.debugInputMonitoringStatus)")
            Divider()
            Button("Open Debug Window…") { openDebugWindow() }
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
