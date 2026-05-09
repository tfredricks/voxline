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

        Button("Debug…") { openDebugWindow() }

        Divider()

        Button("Quit voxline") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
