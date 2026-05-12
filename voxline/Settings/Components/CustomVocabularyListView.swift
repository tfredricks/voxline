import SwiftUI

/// SwiftUI section for managing the global custom-vocabulary list. Rows show
/// each term with a delete button; an inline Add field appends after trim +
/// dedupe; a footer shows `N terms`. Vocab biasing now flows through the LLM
/// cleanup prompt — see
/// `docs/superpowers/specs/2026-05-12-vocab-cleanup-only-pivot-design.md`.
struct CustomVocabularyListView: View {

    @Bindable var viewModel: CustomVocabularyListViewModel

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

            Text("\(viewModel.terms.count) term\(viewModel.terms.count == 1 ? "" : "s")")
                .foregroundStyle(.secondary)
                .font(.callout)
        }
    }
}
