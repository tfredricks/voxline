import SwiftUI

struct MenuBarContent: View {
    @Bindable var state: AppState
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if case .error(let message) = state.status {
            Text(message)
                .foregroundStyle(.red)
            Divider()
        }

        // PLAN 2 ONLY — REMOVED IN PLAN 3 ALONG WITH DebugTranscriptWindow.
        Button("Show Transcripts (debug)…") {
            openWindow(id: "debug-transcripts")
            NSApp.activate()
        }

        Divider()

        Button("Settings…") {
            openSettings()
            // openSettings doesn't activate the app on its own; ensure the
            // settings window comes to the front.
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
