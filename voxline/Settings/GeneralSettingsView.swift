import SwiftUI

struct GeneralSettingsView: View {
    var body: some View {
        Form {
            Text("Hotkey, input device, and Whisper model settings live here. (Plan 4)")
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 320)
    }
}

#Preview {
    GeneralSettingsView()
}
