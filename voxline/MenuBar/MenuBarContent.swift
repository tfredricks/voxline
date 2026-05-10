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

        Button(state.hotkeyEnabled ? "Pause voxline" : "Resume voxline") {
            state.hotkeyEnabled.toggle()
        }
        Divider()

        Button("Settings…") {
            openSettings()
            NSApp.activate()
        }
        .keyboardShortcut(",")

        // Debug window exposes the most recent raw and cleaned dictation
        // text in copyable form. Acceptable in development builds; in
        // release it would let any screenshot/screen-recording leak the
        // last dictation, which can include passwords or 2FA codes the
        // user spoke aloud.
        #if DEBUG
        Divider()
        Button("Debug…") { openDebugWindow() }
        #endif

        Divider()

        Button("Quit voxline") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
