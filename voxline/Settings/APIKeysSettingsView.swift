import SwiftUI

struct APIKeysSettingsView: View {

    @State private var vm = APIKeysSettingsViewModel()

    var body: some View {
        Form {
            Picker("Provider", selection: $vm.provider) {
                ForEach(LLMProvider.allCases, id: \.self) { p in
                    Text(p.displayName).tag(p)
                }
            }
            .pickerStyle(.segmented)

            Section("Anthropic") {
                SecureField("API key", text: $vm.anthropicKey)
                    .textContentType(.password)
            }

            Section("OpenAI") {
                SecureField("API key", text: $vm.openaiKey)
                    .textContentType(.password)
            }

            HStack {
                Spacer()
                Button("Save") { saveWithErrorBanner() }
                    .keyboardShortcut(.defaultAction)
            }

            if let err = vm.lastError {
                Text(err)
                    .foregroundStyle(.red)
                    .font(.callout)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 360)
    }

    private func saveWithErrorBanner() {
        do {
            try vm.save()
            vm.lastError = nil
        } catch {
            vm.lastError = "Save failed: \(error.localizedDescription)"
        }
    }
}

#Preview {
    APIKeysSettingsView()
}
