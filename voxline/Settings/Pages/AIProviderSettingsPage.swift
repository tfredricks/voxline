import SwiftUI

struct AIProviderSettingsPage: View {
    @Bindable var general: GeneralSettingsViewModel
    @Bindable var keys: APIKeysSettingsViewModel
    @State private var revealed = false

    var body: some View {
        SettingsPage(.aiProvider) {
            Section("Provider") {
                Picker("Provider", selection: $general.provider) {
                    ForEach(LLMProvider.allCases, id: \.self) { p in
                        Text(p.displayName).tag(p)
                    }
                }
                .pickerStyle(.segmented)
                Text("Cleans up dictation, runs commands and writes meeting notes.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            // Rebuilt per provider so one provider's editor state can't show
            // under the other; reveal resets so switching never shows a key.
            Section("\(general.provider.displayName) API key") {
                keyRow(for: general.provider)
                    .id(general.provider)
            }
        }
        .onChange(of: general.provider) { _, _ in revealed = false }
    }

    @ViewBuilder
    private func keyRow(for provider: LLMProvider) -> some View {
        switch provider {
        case .anthropic:
            APIKeyRow(
                title: "Anthropic",
                provider: .anthropic,
                key: $keys.anthropicKey,
                revealed: $revealed,
                getKeyURL: URL(string: "https://console.anthropic.com/settings/keys")!,
                expectedPrefix: "sk-ant-",
                isPersisted: keys.isPersisted(.anthropic),
                testing: keys.testing,
                testResult: keys.testResult,
                lastError: keys.lastError,
                onCommit: { keys.commitAnthropic() },
                onTest: { Task { await keys.testConnection(.anthropic) } }
            )
        case .openai:
            OpenAIKeyRow(general: general, keys: keys, revealed: $revealed)
        }
    }
}
