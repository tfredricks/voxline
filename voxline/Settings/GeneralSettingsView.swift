// voxline/Settings/GeneralSettingsView.swift
import SwiftUI

struct GeneralSettingsView: View {

    @State private var vm: GeneralSettingsViewModel

    init(vm: GeneralSettingsViewModel) {
        _vm = State(wrappedValue: vm)
    }

    var body: some View {
        Form {
            Section("Hotkey") {
                ChordRecorderView(chord: $vm.chord)
            }

            Section("Microphone") {
                Picker("Input device", selection: $vm.audioInputDeviceUID) {
                    ForEach(vm.deviceRows) { row in
                        Text(row.label).tag(row.uid)
                    }
                }
            }

            Section("Speech recognition") {
                Picker("Model", selection: $vm.whisperModel) {
                    ForEach(WhisperModel.allCases, id: \.self) { m in
                        Text(m.displayName).tag(m)
                    }
                }
                Text("Switching downloads the new model now (~\(vm.whisperModel.approxSizeMB) MB).")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }

            Section("Cleanup") {
                Picker("Provider", selection: $vm.provider) {
                    ForEach(LLMProvider.allCases, id: \.self) { p in
                        Text(p.displayName).tag(p)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Feedback") {
                Toggle("Play sound on record start/stop", isOn: $vm.playHotkeySounds)
            }

            HStack {
                Spacer()
                Button("Reset to Defaults") { vm.resetToDefaults() }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, idealWidth: 540, minHeight: 380, idealHeight: 460)
    }
}
