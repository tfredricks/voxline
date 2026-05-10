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
                },
                openAboutWindow: {
                    delegate.showAboutWindow()
                },
                tagSettingsWindow: {
                    delegate.tagSettingsWindowSoon()
                }
            )
        } label: {
            MenuBarLabel(state: delegate.appState)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(
                generalVM: GeneralSettingsViewModel(applier: delegate.coordinator),
                apiKeysVM: APIKeysSettingsViewModel()
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
    let aboutWindow = AboutWindowController()
    let windowVisibility = WindowVisibilityCoordinator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        coordinator.startIfNeeded(state: appState)
    }

    func showAboutWindow() {
        let env = SupportEnvironment.current(
            whisperModel: coordinator.transcriber?.model.displayName ?? "(unknown)",
            micDevice: nil
        )
        aboutWindow.show(env: env)
    }

    func tagSettingsWindowSoon() {
        windowVisibility.tagSettingsWindowAfterOpen()
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
    var soundPlayer: HotkeySoundPlayer?

    private var pillWindow: RecordingPillWindow?
    private var downloadWindow: ModelDownloadWindow?
    private var modelPrepTask: Task<Void, Never>?
    /// Monotonic identity for the current modelPrepTask. The inner Task
    /// captures this value at start; the tail clears `modelPrepTask` only
    /// if its captured token still matches, preventing a late-completing
    /// task from clobbering its successor's registration.
    private var modelPrepTaskToken: UInt64 = 0
    private var didStart = false
    /// Held weakly so a settings-driven model swap can route status updates
    /// through the same `AppState` the launch path is using. The AppDelegate
    /// keeps both this coordinator and the state alive for the app lifetime.
    private weak var appState: AppState?
    /// Single 1s timer that reconciles `hotkeyEnabled` + permission state with
    /// the tap's installed/uninstalled status. Replaces the three separate
    /// timers (retry, revocation watchdog, enabled observer) that used to race
    /// over the same eventTap.
    private var permissionPollTimer: Timer?
    private var firstRunWindow: FirstRunWindowController?

    func startIfNeeded(state: AppState) {
        guard !didStart else { return }
        didStart = true
        self.appState = state

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
        self.soundPlayer = HotkeySoundPlayer(settings: settings)
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
        let fieldInspector = AXFocusedFieldInspector()
        self.injector = injector
        self.frontmost = frontmost

        let pipeline = CapturePipeline(
            state: state,
            capture: capture,
            transcriber: transcriber,
            llm: llm,
            modes: router,
            frontmost: frontmost,
            fieldInspector: fieldInspector,
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
            self?.soundPlayer?.playStart()
            self?.pipeline?.startRecording()
            if let state { self?.pillWindow?.updateVisibility(state: state) }
        }
        monitor.onFinalizeRecording = { [weak self, weak state] in
            self?.soundPlayer?.playStop()
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

        // Save the monitor immediately so the unified reconcile loop owns it.
        // The first start() attempt may fail (e.g. AX not granted yet); the
        // loop retries on every tick and clears the error once the tap installs.
        hotkeyMonitor = monitor
        do {
            try monitor.start()
        } catch {
            // macOS doesn't deliver a permission-changed notification to the
            // running process, so the reconcile loop polls until AX/IM are
            // granted and then installs the tap. The user does NOT need to
            // restart the app.
            state.status = .error(category: .permissions, message: "Hotkey monitoring requires Accessibility AND Input Monitoring permission. Grant both in System Settings → Privacy & Security — voxline will pick them up automatically.")
        }

        startPermissionAndStateLoop(state: state)
    }

    /// Single source of truth for "should the tap be installed right now?".
    /// Replaces three separately-timed loops (accessibility-retry, IM watchdog,
    /// hotkey-enabled observer) that used to race against each other when, for
    /// example, the watchdog tore down the tap while the enabled observer was
    /// trying to install it the same second.
    private func startPermissionAndStateLoop(state: AppState) {
        permissionPollTimer?.invalidate()
        permissionPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self, weak state] _ in
            MainActor.assumeIsolated {
                guard let self, let state else { return }
                self.reconcileTapWithPermissionsAndEnabled(state: state)
            }
        }
        // React instantly to user-driven hotkeyEnabled toggles instead of
        // waiting up to 1s for the next poll tick.
        observeHotkeyEnabledChanges(state: state)
    }

    private func reconcileTapWithPermissionsAndEnabled(state: AppState) {
        let perms = PermissionsService()
        let ax = perms.accessibilityStatus
        let im = perms.inputMonitoringStatus
        let mic = perms.microphoneStatus
        state.debugAccessibilityStatus = String(describing: ax)
        state.debugInputMonitoringStatus = String(describing: im)
        state.debugMicrophoneStatus = String(describing: mic)

        guard let monitor = hotkeyMonitor else { return }
        let permissionsOK = (ax == .granted && im == .granted)
        let shouldBeInstalled = state.hotkeyEnabled && permissionsOK
        let isInstalled = monitor.isTapInstalled

        if shouldBeInstalled && !isInstalled {
            do {
                try monitor.start()
                // Clear only the permissions banner that this loop owns.
                // A pipeline or modelPrep error in flight is unrelated to
                // tap installation and must not be silently dismissed.
                if case .error(.permissions, _) = state.status {
                    state.status = .idle
                }
            } catch {
                // tapCreate can lag behind AXIsProcessTrusted; retry next tick.
            }
        } else if !shouldBeInstalled && isInstalled {
            monitor.stop()
            // Distinguish user-initiated pause from involuntary revocation —
            // only the latter deserves an error banner.
            if state.hotkeyEnabled && !permissionsOK {
                state.status = .error(category: .permissions, message: "Accessibility or Input Monitoring permission was revoked. Re-grant it in System Settings → Privacy & Security; voxline will recover automatically.")
            }
        }
    }

    /// Re-arms `withObservationTracking` after each change so we keep getting
    /// callbacks. Calls reconcile immediately on change rather than waiting
    /// for the next poll tick.
    private func observeHotkeyEnabledChanges(state: AppState) {
        withObservationTracking {
            _ = state.hotkeyEnabled
        } onChange: { [weak self, weak state] in
            Task { @MainActor in
                guard let self, let state else { return }
                self.reconcileTapWithPermissionsAndEnabled(state: state)
                self.observeHotkeyEnabledChanges(state: state)
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
        modelPrepTaskToken &+= 1
        let myToken = modelPrepTaskToken
        // When the caller passes `state`, this task takes ownership of
        // `state.status` for its duration. Reset it to match what's about
        // to happen so a stale value (e.g. an inherited
        // `.downloadingModel(progress: 0.37)` from a cancelled launch task
        // after a settings-driven model swap) doesn't surface as a frozen
        // progress bar at the old percentage.
        if let state {
            state.status = TranscriptionService.isModelCached(transcriber.model)
                ? .preparingModel
                : .downloadingModel(progress: 0)
        }
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
                    state.status = .error(category: .modelPrep, message: "Model setup failed: \(error.localizedDescription). Try Retry or relaunch voxline.")
                }
                if managesDownloadWindow {
                    self?.downloadWindow?.close()
                    self?.downloadWindow = nil
                }
            }
            // Only clear modelPrepTask if no newer task has replaced us.
            // Without this guard, a late-finishing prior task would null
            // out the successor's registration, leaving it unreachable
            // for cancel().
            if self?.modelPrepTaskToken == myToken {
                self?.modelPrepTask = nil
            }
        }
    }

    deinit {
        permissionPollTimer?.invalidate()
        modelPrepTask?.cancel()
    }
}

extension AppCoordinator: GeneralSettingsApplier {
    func apply(_ snapshot: GeneralSettingsSnapshot) {
        // snapshot.provider is consumed by LLMService at the next dictation;
        // no per-snapshot action needed here.
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
            // If the launch-path download is still on screen (window not yet
            // dismissed), the new task must take over its state + window
            // ownership. Otherwise the download window would be orphaned and
            // state.status would freeze at the old model's progress
            // percentage. After the launch flow has completed, do a quiet
            // background swap with no UI.
            let inheritsLaunchUI = (downloadWindow != nil)
            runModelPrepTask(
                state: inheritsLaunchUI ? appState : nil,
                transcriber: transcriber,
                managesDownloadWindow: inheritsLaunchUI
            )
        }
    }
}
