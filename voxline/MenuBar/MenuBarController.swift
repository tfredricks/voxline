import SwiftUI

/// Maps AppStatus → SF Symbol name for the menu bar icon.
enum MenuBarIcon {
    static func symbolName(for status: AppStatus) -> String {
        switch status {
        case .idle:        return "mic"
        case .recording:   return "mic.fill"
        case .thinking:    return "ellipsis.circle"
        case .error:       return "mic.slash"
        }
    }
}

struct MenuBarContent: View {
    @Bindable var state: AppState
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if case .error(let message) = state.status {
            Text(message)
                .foregroundStyle(.red)
            Divider()
        }

        Button("Settings…") {
            openSettings()
            // openSettings doesn't activate the app on its own; ensure the
            // settings window comes to the front.
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut(",")

        Divider()

        Button("Quit voxline") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
