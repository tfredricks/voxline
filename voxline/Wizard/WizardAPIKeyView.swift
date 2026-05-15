// voxline/Wizard/WizardAPIKeyView.swift
import SwiftUI

struct WizardAPIKeyView: View {
    @Bindable var vm: APIKeysSettingsViewModel
    @Binding var selectedProvider: LLMProvider

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Set up your API key").font(.title.bold())
            Text("You only need a key for one provider — Voxline uses it for the cleanup step. You can add the other later in Settings.")
                .foregroundStyle(.secondary)

            Picker("Provider", selection: $selectedProvider) {
                Text(LLMProvider.anthropic.displayName).tag(LLMProvider.anthropic)
                Text(LLMProvider.openai.displayName).tag(LLMProvider.openai)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            LabeledContent("\(selectedProvider.displayName) API key") {
                SecureField(placeholder, text: keyBinding)
                    .textContentType(.password)
                    // Force SwiftUI to rebuild the SecureField when the
                    // provider toggle flips. Without this, the field keeps
                    // editor state from the previous provider (cursor pos,
                    // selection) which is confusing — and on some SwiftUI
                    // versions, the binding capture itself can stale.
                    .id(selectedProvider)
            }

            Link("Get a \(selectedProvider.displayName) key →", destination: getKeyURL)
                .font(.callout)

            HStack {
                Button("Test \(selectedProvider.displayName)") {
                    Task { await vm.testConnection(selectedProvider) }
                }
                .disabled(vm.testing != nil || currentKeyEmpty)
                if vm.testing != nil { ProgressView().controlSize(.small) }
                Spacer()
                testResultView
            }

            if let err = vm.lastError {
                Text(err).foregroundStyle(.red).font(.callout)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var keyBinding: Binding<String> {
        switch selectedProvider {
        case .anthropic: return $vm.anthropicKey
        case .openai:    return $vm.openaiKey
        }
    }

    private var placeholder: String {
        switch selectedProvider {
        case .anthropic: return "sk-ant-…"
        case .openai:    return "sk-…"
        }
    }

    private var getKeyURL: URL {
        switch selectedProvider {
        case .anthropic: return URL(string: "https://console.anthropic.com/settings/keys")!
        case .openai:    return URL(string: "https://platform.openai.com/api-keys")!
        }
    }

    private var currentKeyEmpty: Bool {
        keyBinding.wrappedValue.isBlank
    }

    @ViewBuilder
    private var testResultView: some View {
        switch vm.testResult {
        case .untested: EmptyView()
        case .success(let p):
            Label("\(p.displayName) connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(_, let msg):
            Label(msg, systemImage: "xmark.circle.fill").foregroundStyle(.red).font(.callout)
        }
    }
}
