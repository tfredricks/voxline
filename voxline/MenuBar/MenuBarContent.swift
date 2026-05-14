// voxline/MenuBar/MenuBarContent.swift  (replace contents)
import AppKit
import SwiftUI

struct MenuBarContent: View {
    @Bindable var state: AppState
    @Environment(\.openSettings) private var openSettings

    var openDebugWindow: () -> Void = {}
    var openAboutWindow: () -> Void = {}
    var openHistoryWindow: () -> Void = {}
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

        Button("Show history…") { openHistoryWindow() }

        Divider()

        Button("Settings…") {
            // Activate ignoring others so the Settings scene lands above the
            // previously-frontmost app on LSUIElement (menu-bar) apps. See
            // AboutWindowController.show for the full rationale.
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
            tagSettingsWindow()
        }
        .keyboardShortcut(",")

        // TODO: revert — temporarily exposing Debug in Release builds for
        // field diagnostics. Restore the `#if DEBUG` / `#endif` wrapper
        // around the Divider + Button below before shipping.
        Divider()
        Button("Debug…") { openDebugWindow() }

        Divider()

        Button("About Voxline") { openAboutWindow() }

        Divider()

        Button("Quit Voxline") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
