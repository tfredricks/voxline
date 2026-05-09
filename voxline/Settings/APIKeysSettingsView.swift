import SwiftUI

struct APIKeysSettingsView: View {
    var body: some View {
        Form {
            Text("Anthropic and OpenAI API keys live here. (Plan 3)")
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 320)
    }
}

#Preview {
    APIKeysSettingsView()
}
