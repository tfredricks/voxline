import SwiftUI

struct ModesSettingsView: View {
    var body: some View {
        Form {
            Text("Per-app modes (bundle ID + prompt) live here. (Plan 4)")
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 320)
    }
}

#Preview {
    ModesSettingsView()
}
