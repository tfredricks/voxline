import AppKit
import SwiftUI

struct MenuBarContent: View {
    @Bindable var state: AppState
    @Environment(\.openSettings) private var openSettings

    var openAboutWindow: () -> Void = {}
    var openHistoryWindow: () -> Void = {}

    var body: some View {
        if let message = state.status.errorMessage {
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
        }
        .keyboardShortcut(",")

        Divider()

        Button("About Voxline") { openAboutWindow() }

        Divider()

        Button("Quit Voxline") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
