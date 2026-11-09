import SwiftUI

/// SwiftUI section for managing the global custom-vocabulary list. Rows show
/// each term with a delete button; an inline
/// Add field appends after trim + dedupe; the footer counts terms and offers
/// Clear All, which asks first. Vocab biasing flows through the LLM cleanup
/// prompt — see `LLMService.vocabularyParagraph`.
struct CustomVocabularyListView: View {

    @Bindable var viewModel: CustomVocabularyListViewModel
    @State private var confirmingClear = false

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
                Button("Add") { viewModel.addTerm() }
                    .disabled(!viewModel.canAdd)
            }

            HStack {
                Text(viewModel.footer)
                    .foregroundStyle(.secondary)
                    .font(.callout)
                Spacer()
                Button("Clear All…") { confirmingClear = true }
                    .disabled(viewModel.terms.isEmpty)
            }
        }
        .confirmationDialog("Remove all \(viewModel.terms.count) terms?", isPresented: $confirmingClear) {
            Button("Remove All", role: .destructive) { viewModel.clearAll() }
        } message: {
            Text("This can't be undone.")
        }
    }
}
