import SwiftUI

struct CleanupSection: View {

    @Bindable var general: GeneralSettingsViewModel
    @Bindable var keys: APIKeysSettingsViewModel

    @State private var showOtherKey: Bool = false
    @State private var anthropicRevealed = false
    @State private var openaiRevealed = false

    var body: some View {
        Section("Cleanup (AI)") {
            Picker("Provider", selection: $general.provider) {
                ForEach(LLMProvider.allCases, id: \.self) { p in
                    Text(p.displayName).tag(p)
                }
            }
            .pickerStyle(.segmented)
        }

        keyRow(for: general.provider)

        DisclosureGroup(isExpanded: $showOtherKey) {
            keyRow(for: other(general.provider))
        } label: {
            Text("Also store \(other(general.provider).displayName) key")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func keyRow(for provider: LLMProvider) -> some View {
        switch provider {
        case .anthropic:
            APIKeyRow(
                title: "Anthropic",
                provider: .anthropic,
                key: $keys.anthropicKey,
                revealed: $anthropicRevealed,
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
                revealed: $openaiRevealed,
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

    private func other(_ p: LLMProvider) -> LLMProvider {
        p == .anthropic ? .openai : .anthropic
    }
}
