// voxline/MenuBar/MenuBarContent.swift  (replace contents)
import AppKit
import SwiftUI

struct MenuBarContent: View {
    @Bindable var state: AppState
    @Bindable var historyStore: DictationHistoryStore
    @Environment(\.openSettings) private var openSettings

    var openDebugWindow: () -> Void = {}
    var openAboutWindow: () -> Void = {}
    var tagSettingsWindow: () -> Void = {}

    var body: some View {
        if case .error(_, let message) = state.status {
            Text(message)
                .foregroundStyle(.red)
            Divider()
        }

        if case .downloadingModel(let p) = state.status {
            Text("Downloading model — \(Int(p * 100))%")
                .foregroundStyle(.secondary)
            Divider()
        }

        Button(state.hotkeyEnabled ? "Pause Voxline" : "Resume Voxline") {
            state.hotkeyEnabled.toggle()
        }

        Divider()

        DictationHistoryMenu(store: historyStore, state: state)

        Divider()

        Button("Settings…") {
            openSettings()
            NSApp.activate()
            tagSettingsWindow()
        }
        .keyboardShortcut(",")

        #if DEBUG
        Divider()
        Button("Debug…") { openDebugWindow() }
        #endif

        Divider()

        Button("About Voxline") { openAboutWindow() }

        Divider()

        Button("Quit Voxline") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
