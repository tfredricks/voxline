import SwiftUI

struct SettingsView: View {
    let generalVM: GeneralSettingsViewModel

    var body: some View {
        TabView {
            GeneralSettingsView(vm: generalVM)
                .tabItem { Label("General", systemImage: "gear") }

            APIKeysSettingsView()
                .tabItem { Label("API Keys", systemImage: "key") }
        }
    }
}
