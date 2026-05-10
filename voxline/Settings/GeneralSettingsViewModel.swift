import Foundation
import Observation

struct AudioDeviceRow: Identifiable, Equatable {
    let uid: String?
    let label: String
    var id: String { uid ?? "__system_default__" }
}

@Observable
@MainActor
final class GeneralSettingsViewModel {

    var chord: HotkeyChord { didSet { if loaded { commit() } } }
    var audioInputDeviceUID: String? { didSet { if loaded { commit() } } }
    var whisperModel: WhisperModel { didSet { if loaded { commit() } } }
    var playHotkeySounds: Bool { didSet { if loaded { commit() } } }
    var provider: LLMProvider { didSet { if loaded { commit() } } }

    var launchAtLogin: Bool {
        didSet {
            guard loaded, oldValue != launchAtLogin else { return }
            applyLaunchAtLogin()
        }
    }
    private(set) var loginItemStatus: LoginItemService.Status

    private(set) var devices: [AudioDevice] = []

    private var settings: AppSettings
    private let applier: GeneralSettingsApplier
    private let deviceEnumerator: () -> [AudioDevice]
    private var deviceListener: AudioDeviceListener?
    private let loginItemService: LoginItemService
    private var loaded = false

    init(
        settings: AppSettings = AppSettings(),
        applier: GeneralSettingsApplier,
        deviceEnumerator: @escaping () -> [AudioDevice] = AudioDeviceEnumerator.inputDevices,
        loginItemService: LoginItemService? = nil
    ) {
        self.settings = settings
        self.applier = applier
        self.deviceEnumerator = deviceEnumerator
        let resolvedLoginItemService = loginItemService ?? LoginItemService()
        self.loginItemService = resolvedLoginItemService
        self.chord = settings.hotkeyChord
        self.audioInputDeviceUID = settings.audioInputDeviceUID
        self.whisperModel = settings.whisperModel
        self.playHotkeySounds = settings.playHotkeySounds
        self.provider = settings.llmProvider
        let initialStatus = resolvedLoginItemService.status
        self.loginItemStatus = initialStatus
        self.launchAtLogin = (initialStatus == .enabled)
        self.devices = deviceEnumerator()
        self.loaded = true
        self.deviceListener = AudioDeviceListener { [weak self] in
            MainActor.assumeIsolated { self?.refreshDevices() }
        }
    }

    var deviceRows: [AudioDeviceRow] {
        var rows: [AudioDeviceRow] = [AudioDeviceRow(uid: nil, label: "System default")]
        for d in devices {
            let suffix = d.isDefault ? " (default)" : ""
            rows.append(AudioDeviceRow(uid: d.uid, label: d.name + suffix))
        }
        if let uid = audioInputDeviceUID, !devices.contains(where: { $0.uid == uid }) {
            rows.append(AudioDeviceRow(uid: uid, label: "(disconnected) previously selected"))
        }
        return rows
    }

    func refreshDevices() {
        devices = deviceEnumerator()
    }

    /// Re-reads `LoginItemService.status` and reconciles `launchAtLogin` to it.
    /// Called after every toggle and on Settings-window-becomes-key, so external
    /// approval/revocation in System Settings → Login Items reflects back.
    func refreshLoginItemStatus() {
        let s = loginItemService.status
        loginItemStatus = s
        let actual = (s == .enabled)
        if launchAtLogin != actual {
            loaded = false
            launchAtLogin = actual
            loaded = true
        }
    }

    /// Restore Spec defaults: hotkey to Left Ctrl + Left Option, system-default
    /// mic, large-v3-turbo, sounds on. Performs one batched commit so the
    /// applier sees a single coherent snapshot rather than four partial ones.
    /// Launch-at-Login is intentionally left untouched — Reset is for pipeline
    /// settings, not OS-level integration.
    func resetToDefaults() {
        loaded = false
        chord = .default
        audioInputDeviceUID = nil
        whisperModel = .default
        playHotkeySounds = true
        provider = .anthropic
        loaded = true
        commit()
    }

    private func applyLaunchAtLogin() {
        // The setter throws on signing/Tcc issues. Reconcile state to actual
        // backend status either way so the UI doesn't lie.
        try? loginItemService.setEnabled(launchAtLogin)
        refreshLoginItemStatus()
    }

    private func commit() {
        var s = settings
        s.hotkeyChord = chord
        s.audioInputDeviceUID = audioInputDeviceUID
        s.whisperModel = whisperModel
        s.playHotkeySounds = playHotkeySounds
        s.llmProvider = provider
        settings = s
        applier.apply(GeneralSettingsSnapshot(
            chord: chord,
            audioInputDeviceUID: audioInputDeviceUID,
            whisperModel: whisperModel,
            playHotkeySounds: playHotkeySounds,
            provider: provider
        ))
    }
}
