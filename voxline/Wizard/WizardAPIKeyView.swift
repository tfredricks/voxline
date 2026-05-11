// voxline/Wizard/WizardAPIKeyView.swift
import SwiftUI

struct WizardAPIKeyView: View {
    @Bindable var vm: APIKeysSettingsViewModel
    @Binding var selectedProvider: LLMProvider

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Set up your API key").font(.title.bold())
            Text("Voxline uses your own API key for the LLM cleanup step. Pick one provider — you can add the other later in Settings.")
                .foregroundStyle(.secondary)

            Picker("Provider", selection: $selectedProvider) {
                Text(LLMProvider.anthropic.displayName).tag(LLMProvider.anthropic)
                Text(LLMProvider.openai.displayName).tag(LLMProvider.openai)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            LabeledContent("\(selectedProvider.displayName) API key") {
                SecureField("paste key", text: keyBinding)
                    .textContentType(.password)
            }

            HStack {
                Button("Test \(selectedProvider.displayName)") {
                    Task { await vm.testConnection(selectedProvider) }
                }
                .disabled(vm.testing != nil || currentKey.isEmpty)
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

    private var currentKey: String {
        switch selectedProvider {
        case .anthropic: return vm.anthropicKey
        case .openai:    return vm.openaiKey
        }
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
