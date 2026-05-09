// voxline/voxlineApp.swift  (replace contents)
import AppKit
import SwiftUI

@main
struct voxlineApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(
                state: delegate.appState,
                openDebugWindow: {
                    delegate.debugWindow.show(
                        state: delegate.appState,
                        coordinator: delegate.coordinator
                    )
                }
            )
        } label: {
            MenuBarLabel(state: delegate.appState)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(
                generalVM: GeneralSettingsViewModel(applier: delegate.coordinator),
                modesVM: ModesSettingsViewModel(applier: delegate.coordinator)
            )
            .environment(delegate.appState)
        }
        // Plan 2's debug Window scene removed in Plan 3 — paste replaces the
        // verification UI.
    }
}

private struct MenuBarLabel: View {
    @Bindable var state: AppState
    var body: some View {
        Image(systemName: MenuBarIcon.symbolName(for: state.status))
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    let coordinator = AppCoordinator()
    let debugWindow = DebugWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        coordinator.startIfNeeded(state: appState)
    }
}

@MainActor
final class AppCoordinator {
    // Exposed (not private) so the Debug screen can drive end-to-end test
    // buttons (e.g. "test paste", "test LLM", "force unwedge"). Not part of
    // the app's public surface — internal-only.
    var hotkeyMonitor: HotkeyMonitor?
    var pipeline: CapturePipeline?
    var transcriber: TranscriptionService?
    var llm: LLMService?
    var modes: ModeRouter?
    var injector: ClipboardInjector?
    var frontmost: FrontmostApp?
    var capture: AudioCaptureService?

    private var pillWindow: RecordingPillWindow?
    private var downloadWindow: ModelDownloadWindow?
    private var modelPrepTask: Task<Void, Never>?
    private var didStart = false
    private var accessibilityRetryTimer: Timer?
    private var inputMonitoringWatchdog: Timer?
    private var firstRunWindow: FirstRunWindowController?

    func startIfNeeded(state: AppState) {
        guard !didStart else { return }
        didStart = true

        let settings = AppSettings()
        if !settings.hasCompletedFirstRun {
            startWizardThenApp(state: state, settings: settings)
        } else {
            startApp(state: state, settings: settings)
        }
    }

    private func startWizardThenApp(state: AppState, settings: AppSettings) {
        buildServices(state: state, settings: settings)
        guard let transcriber = self.transcriber else { return }

        let wizard = FirstRunWindowController()
        self.firstRunWindow = wizard
        wizard.show(
            state: state,
            settings: settings,
            model: settings.whisperModel,
            chord: settings.hotkeyChord,
            onRetryDownload: { [weak self, weak state] in
                guard let self, let state else { return }
                // Reset the error before retrying so the download progress UI shows again.
                state.status = TranscriptionService.isModelCached(settings.whisperModel)
                    ? .preparingModel
                    : .downloadingModel(progress: 0)
                self.prepareIfNeeded(state: state, transcriber: transcriber)
            },
            onComplete: { [weak self] in
                guard let self else { return }
                self.firstRunWindow = nil
                self.installHotkey(state: state, settings: settings)
            }
        )

        // Eagerly start the model download so by the time the user reaches the
        // download step, progress is already advancing.
        prepareIfNeeded(state: state, transcriber: transcriber)
    }

    private func startApp(state: AppState, settings: AppSettings) {
        buildServices(state: state, settings: settings)
        guard let transcriber = self.transcriber else { return }
        installHotkey(state: state, settings: settings)
        prepareIfNeeded(state: state, transcriber: transcriber)
    }

    private func buildServices(state: AppState, settings: AppSettings) {
        let capture = AudioCaptureService()
        self.capture = capture
        let transcriber = TranscriptionService()
        self.transcriber = transcriber

        // Modes
        let modes: [Mode]
        do {
            let store = try ModeStore()
            modes = try store.load()
        } catch {
            // Fall back to shipped defaults if disk I/O fails — the app should
            // still work; the user just won't have a writable modes.json this
            // session. (Plan 4's Modes editor will surface the disk error.)
            modes = ModeStore.shippedDefaults
        }
        let router = ModeRouter(modes: modes)

        // LLM
        let llm = LLMService(settings: settings, keychain: Keychain())
        self.llm = llm
        self.modes = router

        // Output
        let injector = ClipboardInjector()
        let frontmost = FrontmostApp()
        self.injector = injector
        self.frontmost = frontmost

        let pipeline = CapturePipeline(
            state: state,
            capture: capture,
            transcriber: transcriber,
            llm: llm,
            modes: router,
            frontmost: frontmost,
            injector: injector
        )
        self.pipeline = pipeline

        let pill = RecordingPillWindow()
        pillWindow = pill
        pill.show(state: state)
    }

    private func installHotkey(state: AppState, settings: AppSettings) {
        let monitor = HotkeyMonitor()
        monitor.chord = settings.hotkeyChord
        monitor.onStartRecording = { [weak self, weak state] in
            self?.pipeline?.startRecording()
            if let state { self?.pillWindow?.updateVisibility(state: state) }
        }
        monitor.onFinalizeRecording = { [weak self, weak state] in
            Task { @MainActor in
                await self?.pipeline?.finalizeRecording()
                self?.hotkeyMonitor?.recordingFinished()
                if let state { self?.pillWindow?.updateVisibility(state: state) }
            }
        }
        monitor.onDebugStateChanged = { [weak state] s, installed in
            Task { @MainActor in
                guard let state else { return }
                state.debugHotkeyState = String(describing: s)
                state.debugTapInstalled = installed
            }
        }
        monitor.onDebugFinalizeReason = { [weak state] reason in
            Task { @MainActor in
                state?.debugLastFinalizeReason = reason
            }
        }
        monitor.onDebugFlagEvent = { [weak state] line in
            Task { @MainActor in
                guard let state else { return }
                // Millisecond-precision timestamp so we can measure the
                // actual duration of a chord hold.
                let now = Date()
                let secs = Int(now.timeIntervalSince1970) % 60
                let ms = Int((now.timeIntervalSince1970 - floor(now.timeIntervalSince1970)) * 1000)
                let stamp = String(format: "%02d.%03d", secs, ms)
                let entry = "[\(stamp)s] \(line)"
                state.debugRecentFlagEvents.insert(entry, at: 0)
                if state.debugRecentFlagEvents.count > 20 {
                    state.debugRecentFlagEvents.removeLast(state.debugRecentFlagEvents.count - 20)
                }
            }
        }
        // Input Monitoring is a separate TCC category from Accessibility.
        // Without it, a CGEventTap only fires while voxline itself is the
        // frontmost app — which made hold-to-talk look like it "only works
        // once". Trigger the prompt here so the user can grant it at first
        // launch alongside Accessibility.
        let perms = PermissionsService()
        _ = perms.requestInputMonitoring()
        // CGEvent.tapCreate sometimes-but-not-reliably surfaces the AX prompt.
        // Force it explicitly so first-run users see both dialogs.
        if perms.accessibilityStatus != .granted {
            perms.promptAccessibility()
        }
        // AVAudioEngine.start is supposed to surface the mic prompt on first
        // use but it's unreliable on sandboxed builds — silently records zeros
        // when permission is notDetermined, which transcribes to empty string.
        // Request explicitly at startup.
        if perms.microphoneStatus == .notDetermined {
            Task { _ = await perms.requestMicrophone() }
        }

        do {
            try monitor.start()
            hotkeyMonitor = monitor
            startInputMonitoringWatchdog(state: state)
        } catch {
            // Accessibility wasn't granted yet. Macos doesn't deliver a
            // permission-changed notification to the running process, so
            // poll until it's granted and then install the tap. The user
            // does NOT need to restart the app.
            state.status = .error("Hotkey monitoring requires Accessibility AND Input Monitoring permission. Grant both in System Settings → Privacy & Security — voxline will pick them up automatically.")
            startAccessibilityRetry(state: state, monitor: monitor)
        }

        observeHotkeyEnabled(state: state)
    }

    /// Once the tap is installed, watch for the user toggling Input Monitoring
    /// in System Settings (or revoking it). This is the permission that makes
    /// the chord work outside voxline itself; without it the tap exists but is
    /// silent unless voxline is foreground.
    private func startInputMonitoringWatchdog(state: AppState) {
        inputMonitoringWatchdog?.invalidate()
        inputMonitoringWatchdog = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak state, weak self] _ in
            Task { @MainActor in
                guard let state else { return }
                let perms = PermissionsService()
                let ax = perms.accessibilityStatus
                let im = perms.inputMonitoringStatus
                let mic = perms.microphoneStatus
                state.debugAccessibilityStatus = String(describing: ax)
                state.debugInputMonitoringStatus = String(describing: im)
                state.debugMicrophoneStatus = String(describing: mic)

                // Revocation detection: if the tap was installed but a required
                // permission has been revoked, the chord no longer works. Surface
                // an actionable error and tear down the tap so a future re-grant
                // can re-install it via startAccessibilityRetry.
                if let installed = self?.hotkeyMonitor?.isTapInstalled, installed {
                    if ax != .granted || im != .granted {
                        state.status = .error("Accessibility or Input Monitoring permission was revoked. Re-grant it in System Settings → Privacy & Security; voxline will recover automatically.")
                        self?.hotkeyMonitor?.stop()
                        if let monitor = self?.hotkeyMonitor {
                            self?.startAccessibilityRetry(state: state, monitor: monitor)
                        }
                    }
                }
            }
        }
    }

    private func startAccessibilityRetry(state: AppState, monitor: HotkeyMonitor) {
        accessibilityRetryTimer?.invalidate()
        accessibilityRetryTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self, weak state] _ in
            Task { @MainActor in
                guard let self, let state else { return }
                // Cheap check first to avoid spamming tapCreate while the
                // user hasn't actioned the dialog yet.
                guard PermissionsService().accessibilityStatus == .granted else { return }
                do {
                    try monitor.start()
                    self.hotkeyMonitor = monitor
                    self.accessibilityRetryTimer?.invalidate()
                    self.accessibilityRetryTimer = nil
                    if case .error = state.status {
                        state.status = .idle
                    }
                } catch {
                    // AXIsProcessTrusted said yes but tapCreate still failed.
                    // Try again next tick — the system can lag a little after
                    // the toggle flip.
                }
            }
        }
    }

    private func observeHotkeyEnabled(state: AppState) {
        // Poll once per second — toggling is rare and a notifier would
        // require a rewrite of AppState into Combine.
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self, weak state] _ in
            Task { @MainActor in
                guard let self, let state else { return }
                let enabled = state.hotkeyEnabled
                let installed = self.hotkeyMonitor?.isTapInstalled ?? false
                if enabled && !installed {
                    try? self.hotkeyMonitor?.start()
                } else if !enabled && installed {
                    self.hotkeyMonitor?.stop()
                }
            }
        }
    }

    private func prepareIfNeeded(state: AppState, transcriber: TranscriptionService) {
        let needsDownload = !TranscriptionService.isModelCached(transcriber.model)
        state.status = needsDownload ? .downloadingModel(progress: 0) : .preparingModel
        let window = ModelDownloadWindow()
        downloadWindow = window
        window.show(state: state)
        runModelPrepTask(state: state, transcriber: transcriber, managesDownloadWindow: true)
    }

    /// Single-flight prepare + prewarm. Cancels any in-flight task before
    /// starting a new one so a settings-driven model swap during launch download
    /// doesn't race against the launch-path prepareIfNeeded.
    ///
    /// - Parameters:
    ///   - state: `AppState` to update with progress/idle/error status, or `nil`
    ///     for the settings-swap path which performs a silent background swap.
    ///   - transcriber: The `TranscriptionService` to prepare.
    ///   - managesDownloadWindow: When `true`, closes `downloadWindow` on
    ///     completion or failure (launch path). When `false`, the download window
    ///     is not touched (settings-swap path).
    private func runModelPrepTask(
        state: AppState?,
        transcriber: TranscriptionService,
        managesDownloadWindow: Bool
    ) {
        modelPrepTask?.cancel()
        modelPrepTask = Task { @MainActor [weak self, weak state, weak transcriber] in
            guard let transcriber else { return }
            do {
                if !TranscriptionService.isModelCached(transcriber.model) {
                    try await transcriber.prepareModel { progress in
                        Task { @MainActor in
                            if let state, case .downloadingModel = state.status {
                                state.status = .downloadingModel(progress: progress)
                            }
                        }
                    }
                    if let state, case .downloadingModel = state.status {
                        state.status = .preparingModel
                    }
                }
                try await transcriber.prewarm()
                if let state, case .preparingModel = state.status {
                    state.status = .idle
                }
                if managesDownloadWindow {
                    self?.downloadWindow?.close()
                    self?.downloadWindow = nil
                }
            } catch is CancellationError {
                // A newer prep task superseded this one. Don't surface as a
                // user-facing error.
                return
            } catch {
                if let state {
                    state.status = .error("Model setup failed: \(error.localizedDescription). Try Retry or relaunch voxline.")
                }
                if managesDownloadWindow {
                    self?.downloadWindow?.close()
                    self?.downloadWindow = nil
                }
            }
            self?.modelPrepTask = nil
        }
    }
}

extension AppCoordinator: ModesApplier {
    func apply(modes: [Mode]) {
        // ModeRouter is a value type stored on the coordinator; rebuild it.
        self.modes = ModeRouter(modes: modes)
        // CapturePipeline holds its own reference to ModeRouter; update it too.
        if let router = self.modes {
            pipeline?.modes = router
        }
    }
}

extension AppCoordinator: GeneralSettingsApplier {
    func apply(_ snapshot: GeneralSettingsSnapshot) {
        hotkeyMonitor?.update(chord: snapshot.chord)

        // AudioCaptureService applies preferredInputDeviceUID at next start();
        // CapturePipeline restarts the engine on every chord, so the new device
        // takes effect on the next dictation.
        capture?.preferredInputDeviceUID = snapshot.audioInputDeviceUID

        // Switching Whisper model: invalidate the loaded pipeline; the next
        // transcribe re-loads from the (possibly cached) new variant. Trigger
        // a single-flight background prepare/prewarm so the user doesn't pay
        // it on next dictation. Shares modelPrepTask with the launch path so
        // mid-download swaps cancel cleanly.
        if let transcriber, transcriber.model != snapshot.whisperModel {
            transcriber.model = snapshot.whisperModel
            // Settings-driven swap: no download window — the launch flow already
            // dismissed it, and re-showing it during normal app use is jarring.
            // The user gets a quiet background swap; failure is visible via the
            // menu-bar status indicator.
            runModelPrepTask(state: nil, transcriber: transcriber, managesDownloadWindow: false)
        }
    }
}
