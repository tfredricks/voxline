// voxline/Wizard/WizardAPIKeyView.swift
import SwiftUI

struct WizardAPIKeyView: View {
    @Bindable var vm: APIKeysSettingsViewModel
    @State private var testResult: TestResult = .untested
    @State private var testing = false

    enum TestResult: Equatable { case untested, success, failed(String) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose a provider").font(.title.bold())
            Text("voxline uses your own API key for the LLM cleanup step. Pick a provider and paste a key.")
                .foregroundStyle(.secondary)

            Picker("Provider", selection: $vm.provider) {
                ForEach(LLMProvider.allCases, id: \.self) { p in
                    Text(p.displayName).tag(p)
                }
            }
            .pickerStyle(.segmented)

            if vm.provider == .anthropic {
                SecureField("Anthropic API key", text: $vm.anthropicKey).textContentType(.password)
            } else {
                SecureField("OpenAI API key", text: $vm.openaiKey).textContentType(.password)
            }

            HStack {
                Button("Test connection") { Task { await runTest() } }
                    .disabled(testing || activeKey.isEmpty)
                if testing { ProgressView().controlSize(.small) }
                Spacer()
                resultView
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var activeKey: String {
        vm.provider == .anthropic ? vm.anthropicKey : vm.openaiKey
    }

    @ViewBuilder
    private var resultView: some View {
        switch testResult {
        case .untested: EmptyView()
        case .success: Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let msg): Label(msg, systemImage: "xmark.circle.fill").foregroundStyle(.red).font(.callout)
        }
    }

    private func runTest() async {
        testing = true
        defer { testing = false }
        do {
            try vm.save() // persists key first so client can read it
            let request = LLMRequest(
                model: vm.provider.defaultModel,
                systemPrompt: "Return the word 'ok' and nothing else.",
                userPrompt: "ping",
                temperature: 0
            )
            let client: any LLMClient
            switch vm.provider {
            case .anthropic:
                client = AnthropicClient(apiKey: vm.anthropicKey)
            case .openai:
                client = OpenAIClient(apiKey: vm.openaiKey)
            }
            _ = try await client.cleanup(request)
            testResult = .success
        } catch let err as LLMError {
            testResult = .failed(err.errorDescription ?? "Failed")
        } catch {
            testResult = .failed(error.localizedDescription)
        }
    }
}
