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

            Section("Speech recognition model") {
                Picker("Model", selection: $vm.whisperModel) {
                    ForEach(WhisperModel.allCases, id: \.self) { m in
                        Text(m.displayName).tag(m)
                    }
                }
                Text("Switching downloads the new model now (~\(vm.whisperModel.approxSizeMB) MB).")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }

            Section("Sounds") {
                Toggle("Play sound on record start/stop", isOn: $vm.playHotkeySounds)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 420)
    }
}
