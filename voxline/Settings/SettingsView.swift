import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gear") }

            APIKeysSettingsView()
                .tabItem { Label("API Keys", systemImage: "key") }

            ModesSettingsView()
                .tabItem { Label("Modes", systemImage: "rectangle.3.group") }
        }
    }
}

#Preview {
    SettingsView()
}
