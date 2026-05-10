import SwiftUI

struct SettingsView: View {
    let generalVM: GeneralSettingsViewModel
    let apiKeysVM: APIKeysSettingsViewModel

    var body: some View {
        TabView {
            GeneralSettingsView(vm: generalVM)
                .tabItem { Label("General", systemImage: "gear") }

            APIKeysSettingsView(vm: apiKeysVM)
                .tabItem { Label("API Keys", systemImage: "key") }
        }
    }
}
