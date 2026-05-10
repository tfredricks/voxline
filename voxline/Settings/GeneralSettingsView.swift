// voxline/Settings/GeneralSettingsView.swift
import SwiftUI

struct GeneralSettingsView: View {

    @State private var vm: GeneralSettingsViewModel
    @State private var devices: [AudioDevice] = []

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
                    Text("System default").tag(String?.none)
                    ForEach(devices, id: \.uid) { device in
                        Text(displayLabel(for: device)).tag(String?.some(device.uid))
                    }
                }
            }

            Section("Speech recognition model") {
                Picker("Model", selection: $vm.whisperModel) {
                    ForEach(WhisperModel.allCases, id: \.self) { m in
                        Text(m.displayName).tag(m)
                    }
                }
                Text("Switching downloads the new model on next launch (~\(vm.whisperModel.approxSizeMB) MB).")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }

            Section("Sounds") {
                Toggle("Play sound on record start/stop", isOn: $vm.playHotkeySounds)
            }

            HStack {
                Spacer()
                Button("Save") { saveWithErrorBanner() }
                    .keyboardShortcut(.defaultAction)
            }

            if let err = vm.lastError {
                Text(err)
                    .foregroundStyle(.red)
                    .font(.callout)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 420)
        .onAppear { devices = AudioDeviceEnumerator.inputDevices() }
    }

    private func displayLabel(for device: AudioDevice) -> String {
        device.isDefault ? "\(device.name) (default)" : device.name
    }

    private func saveWithErrorBanner() {
        do {
            try vm.save()
            vm.lastError = nil
        } catch {
            vm.lastError = "Save failed: \(error.localizedDescription)"
        }
    }
}
