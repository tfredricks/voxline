import SwiftUI

/// SwiftUI section for managing the global custom-vocabulary list. Rows show
/// each term with a delete button; an inline Add field appends a new term
/// after trim + dedupe; a footer shows `N terms · X / 200 tokens`.
///
/// All state lives in `CustomVocabularyListViewModel`. The view passes the
/// current `whisperModel` selection so it can re-trigger token-count
/// refresh when the user switches Whisper models.
struct CustomVocabularyListView: View {

    @Bindable var viewModel: CustomVocabularyListViewModel
    let whisperModel: WhisperModel

    var body: some View {
        Section("Custom vocabulary") {
            if viewModel.terms.isEmpty {
                Text("Add names, products, and acronyms that get mis-transcribed.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else {
                ForEach(viewModel.terms, id: \.self) { term in
                    HStack {
                        Text(term)
                        Spacer()
                        Button {
                            viewModel.remove(term)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove \(term)")
                    }
                }
            }

            HStack {
                TextField("Add term", text: $viewModel.draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        if viewModel.canAdd { viewModel.addTerm() }
                    }
                    .onChange(of: viewModel.draft) {
                        Task { await viewModel.refreshCanAdd() }
                    }
                Button("Add") { viewModel.addTerm() }
                    .disabled(!viewModel.canAdd)
            }

            HStack(spacing: 6) {
                Text("\(viewModel.terms.count) term\(viewModel.terms.count == 1 ? "" : "s") · \(viewModel.tokenCount) / \(viewModel.budget) tokens")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                if viewModel.tokenCountIsApproximate {
                    Text("(approximate — Whisper model not yet loaded)")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
            }
        }
        .task {
            await viewModel.refreshCount()
        }
        .onChange(of: whisperModel) {
            Task { await viewModel.refreshCount() }
        }
    }
}
