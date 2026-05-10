import SwiftUI

struct APIKeysSettingsView: View {

    private enum Field: Hashable { case anthropic, openai }

    @State private var vm: APIKeysSettingsViewModel
    @State private var anthropicRevealed = false
    @State private var openaiRevealed = false
    @FocusState private var focused: Field?

    init(vm: APIKeysSettingsViewModel) {
        _vm = State(wrappedValue: vm)
    }

    var body: some View {
        Form {
            keySection(
                title: "Anthropic",
                provider: .anthropic,
                key: $vm.anthropicKey,
                revealed: $anthropicRevealed,
                getKeyURL: URL(string: "https://console.anthropic.com/settings/keys")!,
                expectedPrefix: "sk-ant-"
            )

            keySection(
                title: "OpenAI",
                provider: .openai,
                key: $vm.openaiKey,
                revealed: $openaiRevealed,
                getKeyURL: URL(string: "https://platform.openai.com/api-keys")!,
                expectedPrefix: "sk-"
            )

            HStack {
                Button("Test Anthropic") { Task { await vm.testConnection(.anthropic) } }
                    .disabled(vm.testing != nil || vm.anthropicKey.isEmpty)
                Button("Test OpenAI") { Task { await vm.testConnection(.openai) } }
                    .disabled(vm.testing != nil || vm.openaiKey.isEmpty)
                if vm.testing != nil { ProgressView().controlSize(.small) }
                Spacer()
                testResultLabel
            }

            if let err = vm.lastError {
                Text(err).foregroundStyle(.red).font(.callout)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, idealWidth: 540, minHeight: 380, idealHeight: 460)
        .onChange(of: focused) { previous, _ in commit(previous) }
        .onDisappear { commit(focused) }
    }

    private func commit(_ field: Field?) {
        switch field {
        case .anthropic: vm.commitAnthropic()
        case .openai:    vm.commitOpenAI()
        case .none:      break
        }
    }

    @ViewBuilder
    private func keySection(
        title: String,
        provider: LLMProvider,
        key: Binding<String>,
        revealed: Binding<Bool>,
        getKeyURL: URL,
        expectedPrefix: String
    ) -> some View {
        let field: Field = (provider == .anthropic) ? .anthropic : .openai
        Section(title) {
            HStack {
                Group {
                    if revealed.wrappedValue {
                        TextField("API key", text: key)
                    } else {
                        SecureField("API key", text: key)
                    }
                }
                .textContentType(.password)
                .focused($focused, equals: field)
                .onSubmit {
                    if provider == .anthropic { vm.commitAnthropic() } else { vm.commitOpenAI() }
                }

                Button {
                    revealed.wrappedValue.toggle()
                } label: {
                    Image(systemName: revealed.wrappedValue ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .help(revealed.wrappedValue ? "Hide key" : "Reveal key")

                statusPill(
                    saved: vm.isPersisted(provider),
                    empty: key.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }

            HStack(spacing: 8) {
                Link("Get a key →", destination: getKeyURL)
                    .font(.callout)
                Spacer()
                let trimmedKey = key.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedKey.isEmpty, !trimmedKey.hasPrefix(expectedPrefix) {
                    Label("Expected prefix \(expectedPrefix)", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
            }
        }
    }

    @ViewBuilder
    private func statusPill(saved: Bool, empty: Bool) -> some View {
        if empty {
            EmptyView()
        } else if saved {
            Text("Saved")
                .font(.caption)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.green.opacity(0.2), in: Capsule())
                .foregroundStyle(.green)
        } else {
            Text("Unsaved")
                .font(.caption)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.orange.opacity(0.2), in: Capsule())
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var testResultLabel: some View {
        switch vm.testResult {
        case .untested: EmptyView()
        case .success(let p):
            Label("\(p.displayName) connected", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green).font(.callout)
        case .failed(_, let msg):
            Label(msg, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red).font(.callout)
        }
    }
}
