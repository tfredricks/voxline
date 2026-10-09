import SwiftUI

struct LearningSection: View {

    @Bindable var model: LearningSettingsViewModel
    @State private var confirmingReset = false
    @State private var confirmingRegenerate: ModeCategory?

    var body: some View {
        Section("Learning") {
            Toggle("Learn words from my corrections", isOn: $model.learnWords)
            Text("When you fix a dictated name or term in the field, voxline adds it to Custom vocabulary.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Toggle("Learn my writing style", isOn: $model.learnStyle)
            Text("Keeps your recent dictations on this Mac and turns them into a short style note per kind of app. The note and two recent examples are sent with each cleanup. Turning this off keeps what was learned until you reset it.")
                .font(.callout)
                .foregroundStyle(.secondary)

            if model.learnStyle {
                ForEach(ModeCategory.allCases, id: \.self) { category in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(category.displayName).font(.headline)
                        TextField("Style note", text: noteBinding(category), axis: .vertical)
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(3...10)
                            .font(.callout)
                        HStack {
                            Text(model.status(for: category))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Regenerate") {
                                if model.needsRegenerateConfirmation(category) {
                                    confirmingRegenerate = category
                                } else {
                                    model.regenerate(category)
                                }
                            }
                            .disabled(!model.canRegenerate(category))
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button("Reset Learning…") { confirmingReset = true }
            }
        }
        .confirmationDialog("Reset learning?", isPresented: $confirmingReset) {
            Button("Reset Learning", role: .destructive) { model.resetLearning() }
        } message: {
            Text("Forget style notes, the dictations they were learned from, and \(model.learnedWordCount) learned words? Words you added yourself stay.")
        }
        .confirmationDialog(
            "Replace your edited note?",
            isPresented: Binding(get: { confirmingRegenerate != nil }, set: { if !$0 { confirmingRegenerate = nil } }),
            presenting: confirmingRegenerate
        ) { category in
            Button("Replace") { model.regenerate(category) }
        }
        .onDisappear { model.commitAllDrafts() }
    }

    private func noteBinding(_ category: ModeCategory) -> Binding<String> {
        Binding(get: { model.note(for: category) }, set: { model.editNote($0, for: category) })
    }
}
