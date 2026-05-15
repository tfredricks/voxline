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

                saveAffordance
            }

            HStack(spacing: 8) {
                Link("Get a \(title) key →", destination: getKeyURL).font(.callout)
                Spacer()
                let trimmed = key.trimmed
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
                // Commit the live value before hitting the network so the
                // user doesn't end up with a successful test against an
                // unsaved key. macOS SwiftUI doesn't reliably defocus a
                // SecureField when another button in the same Form is
                // clicked, so .onChange(of: focused) can't be relied on.
                Button("Test") { onCommit(); onTest() }
                    .disabled(testing != nil || key.isBlank)
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

    // Save button when dirty, green "Saved" pill when persisted. Replaces the
    // earlier "Unsaved" pill, which was a status indicator with no action
    // attached — users had no discoverable way to commit (the only paths were
    // pressing Return or losing focus, neither obvious nor reliable on macOS
    // SwiftUI's SecureField + Form combo).
    @ViewBuilder
    private var saveAffordance: some View {
        let trimmedEmpty = key.isBlank
        if trimmedEmpty {
            EmptyView()
        } else if isPersisted {
            Text("Saved")
                .font(.caption)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.green.opacity(0.2), in: Capsule())
                .foregroundStyle(.green)
        } else {
            Button("Save") { onCommit() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
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
