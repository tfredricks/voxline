import SwiftUI

struct CommandsSettingsPage: View {
    @Bindable var general: GeneralSettingsViewModel
    let command: CommandSettingsViewModel

    var body: some View {
        SettingsPage(.commands) {
            Section {
                Toggle("Command mode", isOn: $general.commandModeEnabled)
                if general.commandModeEnabled {
                    ChordRecorderView(
                        chord: Binding(
                            get: { general.commandChord ?? .defaultCommand },
                            set: { general.commandChord = $0 }
                        ),
                        title: "Hotkey",
                        validate: general.validateCommandChord
                    )
                }
                Text("Hold to speak an edit: rewrite the selection, draft a reply, or change part of the field.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }

            Section("Model") {
                CommittingTextField(
                    title: "Command model",
                    value: general.commandModel,
                    prompt: general.cleanupModelPlaceholder
                ) { general.commandModel = $0 }
                Text("Leave empty to use the cleanup model. A larger model drafts and answers better but responds more slowly.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }

            Section("Presets") {
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
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
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
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            if let warning = model.warning(for: preset.id) {
                Text(warning)
                    .foregroundStyle(.orange)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
