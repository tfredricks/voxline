import SwiftUI

struct CleanupSection: View {

    @Bindable var general: GeneralSettingsViewModel
    @Bindable var keys: APIKeysSettingsViewModel

    @State private var revealed = false

    var body: some View {
        Section("Cleanup (AI)") {
            Picker("Default provider", selection: $general.provider) {
                ForEach(LLMProvider.allCases, id: \.self) { p in
                    Text(p.displayName).tag(p)
                }
            }
            .pickerStyle(.segmented)
        }

        // One key row at a time, bound to the picker's provider. Switching
        // the picker swaps which key is visible; saving writes that key to
        // its provider's keychain slot. The `.id(general.provider)` forces
        // SwiftUI to rebuild APIKeyRow on switch so editor state from the
        // previous provider can't bleed through. `revealed` is intentionally
        // reset on switch so we never reveal the new provider's key just
        // because the previous one was being shown in plaintext.
        keyRow(for: general.provider)
            .id(general.provider)
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
            APIKeyRow(
                title: "OpenAI",
                provider: .openai,
                key: $keys.openaiKey,
                revealed: $revealed,
                getKeyURL: URL(string: "https://platform.openai.com/api-keys")!,
                expectedPrefix: "sk-",
                isPersisted: keys.isPersisted(.openai),
                testing: keys.testing,
                testResult: keys.testResult,
                lastError: keys.lastError,
                onCommit: { keys.commitOpenAI() },
                onTest: { Task { await keys.testConnection(.openai) } }
            )
        }
    }
}
