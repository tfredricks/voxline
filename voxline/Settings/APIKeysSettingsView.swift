import SwiftUI

struct APIKeysSettingsView: View {

    private enum Field: Hashable { case anthropic, openai }

    @State private var vm: APIKeysSettingsViewModel
    @FocusState private var focused: Field?

    init(vm: APIKeysSettingsViewModel) {
        _vm = State(wrappedValue: vm)
    }

    var body: some View {
        Form {
            Section("Anthropic") {
                SecureField("API key", text: $vm.anthropicKey)
                    .textContentType(.password)
                    .focused($focused, equals: .anthropic)
                    .onSubmit { vm.commitAnthropic() }
            }
            Section("OpenAI") {
                SecureField("API key", text: $vm.openaiKey)
                    .textContentType(.password)
                    .focused($focused, equals: .openai)
                    .onSubmit { vm.commitOpenAI() }
            }

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
        .frame(minWidth: 480, idealWidth: 540, minHeight: 320, idealHeight: 380)
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
