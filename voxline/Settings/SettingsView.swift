import SwiftUI

struct SettingsView: View {
    let generalVM: GeneralSettingsViewModel
    let modesVM: ModesSettingsViewModel

    var body: some View {
        TabView {
            GeneralSettingsView(vm: generalVM)
                .tabItem { Label("General", systemImage: "gear") }

            APIKeysSettingsView()
                .tabItem { Label("API Keys", systemImage: "key") }

            ModesSettingsView(vm: modesVM)
                .tabItem { Label("Modes", systemImage: "rectangle.3.group") }
        }
    }
}
