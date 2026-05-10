import SwiftUI

struct APIKeyRow: View {

    let title: String
    let provider: LLMProvider
    @Binding var key: String
    @Binding var revealed: Bool
    let getKeyURL: URL
    let expectedPrefix: String
    let isPersisted: Bool
    let testing: LLMProvider?
    let testResult: APIKeyTestResult
    let lastError: String?
    var onCommit: () -> Void
    var onTest: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        Section(title) {
            HStack {
                Group {
                    if revealed {
                        TextField("API key", text: $key)
                    } else {
                        SecureField("API key", text: $key)
                    }
                }
                .textContentType(.password)
                .focused($focused)
                .onSubmit(onCommit)

                Button {
                    revealed.toggle()
                } label: {
                    Image(systemName: revealed ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .help(revealed ? "Hide key" : "Reveal key")

                statusPill
            }

            HStack(spacing: 8) {
                Link("Get a \(title) key →", destination: getKeyURL).font(.callout)
                Spacer()
                let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
                let prefixMismatch = !trimmed.isEmpty && !trimmed.hasPrefix(expectedPrefix)
                let antInOpenAI = (provider == .openai) && trimmed.hasPrefix("sk-ant-")
                if prefixMismatch || antInOpenAI {
                    Label(
                        antInOpenAI ? "This looks like an Anthropic key" : "Expected prefix \(expectedPrefix)",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                    .font(.callout)
                }
            }

            HStack {
                Button("Test") { onTest() }
                    .disabled(testing != nil || key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if testing == provider { ProgressView().controlSize(.small) }
                testResultLabel
                Spacer()
            }

            if let err = lastError {
                Text(err).foregroundStyle(.red).font(.callout)
            }
        }
        .onChange(of: focused) { _, isFocused in
            if !isFocused { onCommit() }
        }
    }

    @ViewBuilder
    private var statusPill: some View {
        let trimmedEmpty = key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if trimmedEmpty {
            EmptyView()
        } else if isPersisted {
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
        switch testResult {
        case .untested: EmptyView()
        case .success(let p) where p == provider:
            Label("Connected", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green).font(.callout)
        case .failed(let p, let msg) where p == provider:
            Label(msg, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red).font(.callout)
        default: EmptyView()
        }
    }
}
