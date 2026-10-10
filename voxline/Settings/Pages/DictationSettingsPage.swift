import SwiftUI

struct DictationSettingsPage: View {
    @Environment(AppState.self) private var appState
    @Environment(\.controlActiveState) private var windowActivity
    @Bindable var general: GeneralSettingsViewModel
    @Bindable var keys: APIKeysSettingsViewModel
    @State private var levelMonitor: MicLevelMonitor?
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
                    if let levelMonitor {
                        MicLevelMeter(monitor: levelMonitor)
                    } else {
                        Color.clear.frame(height: 8)
                    }
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
            if levelMonitor == nil { levelMonitor = MicLevelMonitor() }
            levelMonitor?.preferredInputDeviceUID = general.audioInputDeviceUID
            updateMonitor()
        }
        .onDisappear { levelMonitor?.stop() }
        .onChange(of: general.audioInputDeviceUID) { _, newValue in
            levelMonitor?.stop()
            levelMonitor?.preferredInputDeviceUID = newValue
            updateMonitor()
        }
        .onChange(of: appState.status) { _, _ in updateMonitor() }
        .onChange(of: windowActivity) { _, _ in updateMonitor() }
    }

    /// The live meter holds the microphone open, so it runs only while
    /// voxline isn't recording and the window is in front of the active app.
    /// `onDisappear` doesn't fire for a minimised, hidden, or background
    /// window; the window going inactive stops the meter instead.
    static func monitorsLevel(status: AppStatus, windowActivity: ControlActiveState) -> Bool {
        status != .recording && windowActivity != .inactive
    }

    private func updateMonitor() {
        if Self.monitorsLevel(status: appState.status, windowActivity: windowActivity) {
            try? levelMonitor?.start()
        } else {
            levelMonitor?.stop()
        }
    }
}
