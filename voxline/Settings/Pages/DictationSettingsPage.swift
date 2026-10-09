import SwiftUI

struct DictationSettingsPage: View {
    @Environment(AppState.self) private var appState
    @Bindable var general: GeneralSettingsViewModel
    @Bindable var keys: APIKeysSettingsViewModel
    @State private var levelMonitor = MicLevelMonitor()
    @State private var keyRevealed = false

    var body: some View {
        SettingsPage(.dictation) {
            Section("Hotkey") {
                ChordRecorderView(
                    chord: $general.chord,
                    title: "Dictation",
                    validate: general.validateDictationChord
                )
                Text("Hold to dictate; release to insert the cleaned-up text.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Microphone") {
                Picker("Input device", selection: $general.audioInputDeviceUID) {
                    ForEach(general.deviceRows) { row in
                        Text(row.label).tag(row.uid)
                    }
                }
                HStack(spacing: 6) {
                    Text("Live level")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                    MicLevelMeter(monitor: levelMonitor)
                }
            }

            Section("Recognition") {
                Picker("Engine", selection: $general.engine) {
                    ForEach(EngineID.allCases, id: \.self) { e in
                        Text(e.displayName).tag(e)
                    }
                }
                switch general.engine {
                case .whisperKit:
                    Picker("Whisper model", selection: $general.whisperModel) {
                        ForEach(WhisperModel.allCases, id: \.self) { m in
                            let cached = TranscriptionService.isModelCached(m)
                            let label = cached
                                ? "\(m.displayName) — ✓ downloaded"
                                : "\(m.displayName) — to download · \(m.approxSizeMB) MB"
                            Text(label).tag(m)
                        }
                    }
                    Text("Switching downloads the new model on demand.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                case .openAIRealtime:
                    Text("Audio is sent to OpenAI and transcribed with your OpenAI API key.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                    if let warning = general.openAIKeyWarning {
                        Text(warning)
                            .foregroundStyle(.orange)
                            .font(.callout)
                    }
                case .apple:
                    EmptyView()
                }
                if general.showsOpenAIKeyInRecognition {
                    OpenAIKeyRow(general: general, keys: keys, revealed: $keyRevealed)
                }
            }
        }
        .onAppear {
            levelMonitor.preferredInputDeviceUID = general.audioInputDeviceUID
            startMonitorIfAllowed()
        }
        .onDisappear { levelMonitor.stop() }
        .onChange(of: general.audioInputDeviceUID) { _, newValue in
            levelMonitor.stop()
            levelMonitor.preferredInputDeviceUID = newValue
            startMonitorIfAllowed()
        }
        .onChange(of: appState.status) { _, newStatus in
            if newStatus == .recording {
                levelMonitor.stop()
            } else {
                startMonitorIfAllowed()
            }
        }
    }

    private func startMonitorIfAllowed() {
        guard appState.status != .recording else { return }
        try? levelMonitor.start()
    }
}
