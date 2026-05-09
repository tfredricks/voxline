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

        Button("Quit voxline") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
