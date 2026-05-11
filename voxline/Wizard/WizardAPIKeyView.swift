// voxline/Wizard/WizardAPIKeyView.swift
import SwiftUI

struct WizardAPIKeyView: View {
    @Bindable var vm: APIKeysSettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Set up API keys").font(.title.bold())
            Text("Voxline uses your own API key for the LLM cleanup step. Paste a key for the provider you want to use.")
                .foregroundStyle(.secondary)

            LabeledContent("Anthropic") {
                SecureField("API key", text: $vm.anthropicKey).textContentType(.password)
            }

            LabeledContent("OpenAI") {
                SecureField("API key", text: $vm.openaiKey).textContentType(.password)
            }

            HStack {
                Button("Test Anthropic") { Task { await vm.testConnection(.anthropic) } }
                    .disabled(vm.testing != nil || vm.anthropicKey.isEmpty)
                Button("Test OpenAI") { Task { await vm.testConnection(.openai) } }
                    .disabled(vm.testing != nil || vm.openaiKey.isEmpty)
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
