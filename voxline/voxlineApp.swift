import SwiftUI

@main
struct voxlineApp: App {

    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(state: appState)
        } label: {
            Image(systemName: MenuBarIcon.symbolName(for: appState.status))
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environment(appState)
        }
    }
}
