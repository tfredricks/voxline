import SwiftUI

/// Edits a draft and hands it to `commit` on Return, on focus loss, and when
/// the field goes away, rather than on every keystroke. A draft equal to
/// `value` commits nothing. `prompt` defaults to `title`.
struct CommittingTextField: View {

    let title: String
    let value: String
    let prompt: String?
    let axis: Axis
    let commit: (String) -> Void

    @State private var draft: String
    @FocusState private var focused: Bool

    init(
        title: String,
        value: String,
        prompt: String? = nil,
        axis: Axis = .horizontal,
        commit: @escaping (String) -> Void
    ) {
        self.title = title
        self.value = value
        self.prompt = prompt
        self.axis = axis
        self.commit = commit
        _draft = State(initialValue: value)
    }

    var body: some View {
        TextField(title, text: $draft, prompt: Text(prompt ?? title), axis: axis)
            .focused($focused)
            .onSubmit { commitDraft() }
            .onChange(of: value) { _, newValue in draft = newValue }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { commitDraft() }
            }
            .onDisappear { commitDraft() }
    }

    private func commitDraft() {
        guard draft != value else { return }
        commit(draft)
    }
}
