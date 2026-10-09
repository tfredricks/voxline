import SwiftUI

/// SwiftUI section for managing the global custom-vocabulary list. Rows show
/// each term, marked when Learning added it, with a delete button; an inline
/// Add field appends after trim + dedupe; the footer counts terms and offers
/// Clear All, which asks first. Vocab biasing flows through the LLM cleanup
/// prompt — see `LLMService.transcriptionPreamble`.
struct CustomVocabularyListView: View {

    @Bindable var viewModel: CustomVocabularyListViewModel
    @State private var confirmingClear = false

    var body: some View {
        Section("Custom vocabulary") {
            if viewModel.entries.isEmpty {
                Text("Add names, products, and acronyms that get mis-transcribed.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else {
                ForEach(viewModel.entries, id: \.term) { entry in
                    HStack {
                        Text(entry.term)
                        if entry.source == .learned {
                            Text("Learned")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            viewModel.remove(entry.term)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove \(entry.term)")
                    }
                }
            }

            HStack {
                TextField("Add term", text: $viewModel.draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        if viewModel.canAdd { viewModel.addTerm() }
                    }
                Button("Add") { viewModel.addTerm() }
                    .disabled(!viewModel.canAdd)
            }

            HStack {
                Text(viewModel.footer)
                    .foregroundStyle(.secondary)
                    .font(.callout)
                Spacer()
                Button("Clear All…") { confirmingClear = true }
                    .disabled(viewModel.entries.isEmpty)
            }
        }
        .confirmationDialog("Remove all \(viewModel.entries.count) terms?", isPresented: $confirmingClear) {
            Button("Remove All", role: .destructive) { viewModel.clearAll() }
        } message: {
            Text("This can't be undone.")
        }
    }
}
