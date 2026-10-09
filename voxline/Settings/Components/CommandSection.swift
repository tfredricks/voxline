import SwiftUI

struct CommandSection: View {

    @Bindable var general: GeneralSettingsViewModel
    let command: CommandSettingsViewModel

    var body: some View {
        Section("Command") {
            VStack(alignment: .leading, spacing: 6) {
                TextField("Command model", text: $general.commandModel, prompt: Text(general.cleanupModelPlaceholder))
                Text("Leave empty to use the cleanup model. A larger model drafts and answers better but responds more slowly.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }

            ForEach(command.presets) { preset in
                PresetRow(preset: preset, model: command)
            }

            HStack {
                Button("Add preset") { command.addPreset() }
                Button("Restore default presets") { command.restoreDefaults() }
            }
            Text("Preset shortcuts work everywhere and are captured even with nothing selected. ⌥1 ⌥2 ⌥3 normally type ¡ ™ £ — remap them if you use those characters.")
                .foregroundStyle(.secondary)
                .font(.callout)
        }
    }
}

private struct PresetRow: View {

    let preset: PresetShortcut
    let model: CommandSettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                KeyComboRecorderView(
                    combo: preset.needsShortcut ? nil : preset.combo,
                    onRecord: { model.updateCombo($0, for: preset.id) }
                )
                CommittingTextField(title: "Name", value: preset.name) {
                    model.updateName($0, for: preset.id)
                }
                Button {
                    model.remove(preset.id)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove \(preset.name)")
            }
            CommittingTextField(title: "Instruction", value: preset.instruction, axis: .vertical) {
                model.updateInstruction($0, for: preset.id)
            }
            if let warning = model.warning(for: preset.id) {
                Text(warning)
                    .foregroundStyle(.orange)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Edits a draft and hands it to `commit` on Return, on focus loss, and when
/// the field goes away, rather than on every keystroke.
private struct CommittingTextField: View {

    let title: String
    let value: String
    let axis: Axis
    let commit: (String) -> Void

    @State private var draft: String
    @FocusState private var focused: Bool

    init(title: String, value: String, axis: Axis = .horizontal, commit: @escaping (String) -> Void) {
        self.title = title
        self.value = value
        self.axis = axis
        self.commit = commit
        _draft = State(initialValue: value)
    }

    var body: some View {
        TextField(title, text: $draft, prompt: Text(title), axis: axis)
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .focused($focused)
            .onSubmit { commit(draft) }
            .onChange(of: value) { _, newValue in draft = newValue }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { commit(draft) }
            }
            .onDisappear { commit(draft) }
    }
}
