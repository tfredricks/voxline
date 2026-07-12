import AppKit
import SwiftUI

@main
struct voxlineApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        // Dev/test entry point: scripts/reset-local-state.sh invokes the signed
        // app binary with this flag so it can delete data-protection-keychain
        // items the bare `security` CLI cannot reach (DPK items are gated by
        // the app's keychain-access-groups entitlement). Runs before any UI
        // appears and exits the process when done.
        if CommandLine.arguments.contains("--reset-keys") {
            let dpk = DataProtectionKeychain()
            for account in KeychainAccount.all {
                do { try dpk.delete(forKey: account) }
                catch { fputs("Voxline --reset-keys: failed to delete DPK \(account): \(error)\n", stderr) }
            }
            fputs("Voxline: cleared keychain entries (anthropic, openai)\n", stderr)
            exit(0)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(
                state: delegate.appState,
                updateService: delegate.updateService,
                openAboutWindow: {
                    delegate.showAboutWindow()
                },
                openHistoryWindow: {
                    delegate.historyWindow.show(
                        store: delegate.historyStore,
                        state: delegate.appState
                    )
                },
                openPermissionsWindow: {
                    NSApp.activate(ignoringOtherApps: true)
                    delegate.coordinator.showPermissionsWindow()
                }
            )
        } label: {
            MenuBarLabel(state: delegate.appState, updateService: delegate.updateService)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(
                generalVM: GeneralSettingsViewModel(onApply: { [weak coordinator = delegate.coordinator] snapshot in
                    coordinator?.apply(snapshot)
                }),
                apiKeysVM: APIKeysSettingsViewModel()
            )
            .environment(delegate.appState)
            .environment(delegate.updateService)
        }
    }
}

private struct MenuBarLabel: View {
    @Bindable var state: AppState
    @Bindable var updateService: UpdateService
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: MenuBarIcon.symbolName(for: state.status, paused: !state.hotkeyEnabled))
            if updateService.hasPendingUpdate {
                Circle()
                    .fill(.blue)
                    .frame(width: 5, height: 5)
                    .offset(x: 2, y: -2)
                    .accessibilityLabel("Update available")
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    let historyStore = DictationHistoryStore()
    let coordinator = AppCoordinator()
    let aboutWindow = AboutWindowController()
    let historyWindow = HistoryWindowController()
    let windowVisibility = WindowVisibilityCoordinator()
    let dictationActivity = DictationActivityMonitor()
    lazy var updateService = UpdateService(dictationActivity: dictationActivity)

    func applicationDidFinishLaunching(_ notification: Notification) {
        windowVisibility.start()
        coordinator.startIfNeeded(state: appState, historyStore: historyStore)
        _ = updateService // force-init so Sparkle's scheduler starts
        observeStatusForUpdates()
    }

    /// Mirrors the `observeHotkeyEnabledChanges` / `observeToastChanges`
    /// pattern in `AppCoordinator`: each fire re-arms the tracker so we
    /// keep getting callbacks across the lifetime of the app.
    private func observeStatusForUpdates() {
        withObservationTracking {
            _ = appState.status
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.dictationActivity.observe(status: self.appState.status)
                self.observeStatusForUpdates()
            }
        }
        // Also seed the initial value.
        dictationActivity.observe(status: appState.status)
    }

    func showAboutWindow() {
        let env = SupportEnvironment.current(
            whisperModel: coordinator.transcriber?.model.displayName ?? "(unknown)"
        )
        aboutWindow.show(env: env)
    }
}

@MainActor
final class AppCoordinator {
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
    /// the tap's installed/uninstalled status. One timer prevents the
    /// accessibility-retry, IM watchdog, and hotkey-enabled paths from racing
    /// against each other over the same eventTap.
    private var permissionPollTimer: Timer?
    private var firstRunWindow: FirstRunWindowController?
    private let permissionsWindow = PermissionsWindowController()
    /// Tracks the required-permission state across reconcile ticks so we can
    /// raise the permissions window on a granted→missing transition (runtime
    /// revocation) without re-raising it every tick while it stays missing.
    private var lastRequiredGranted: Bool?

    /// Raise the standalone permissions panel. Called from the menu-bar
    /// "Fix permissions…" item and from the startup / revocation guards.
    func showPermissionsWindow() {
        permissionsWindow.show()
    }

    func startIfNeeded(state: AppState, historyStore: DictationHistoryStore) {
        guard !didStart else { return }
        didStart = true
        self.appState = state

        let settings = AppSettings()
        logLaunchTrace(settings: settings)
        if !settings.hasCompletedFirstRun {
            startWizardThenApp(state: state, settings: settings, historyStore: historyStore)
        } else {
            startApp(state: state, settings: settings, historyStore: historyStore)
        }
    }

    private func startWizardThenApp(state: AppState, settings: AppSettings, historyStore: DictationHistoryStore) {
        buildServices(state: state, settings: settings, historyStore: historyStore)
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

    private func startApp(state: AppState, settings: AppSettings, historyStore: DictationHistoryStore) {
        buildServices(state: state, settings: settings, historyStore: historyStore)
        guard let transcriber = self.transcriber else { return }
        installHotkey(state: state, settings: settings)
        prepareIfNeeded(state: state, transcriber: transcriber)
    }

    private func buildServices(state: AppState, settings: AppSettings, historyStore: DictationHistoryStore) {
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
            AppLog.pipeline.error("modes load failed, using shipped defaults: \(error.localizedDescription)")
            modes = ModeStore.shippedDefaults
        }
        let router = ModeRouter(modes: modes)

        // LLM
        let llm = LLMService(settings: settings, keychain: DataProtectionKeychain())
        self.llm = llm
        self.modes = router

        // Output
        let focusedTextSystem = AXFocusedTextSystem()
        let chordProvider: @Sendable () -> HotkeyChord = { AppSettings().hotkeyChord }
        // Paste eligibility must fail OPEN under the App Sandbox. The
        // DefaultPasteEligibility pre-flight decides "is this a paste target?"
        // purely from cross-app AX reads (menu-bar Paste item + focused-field
        // value) — both of which the sandbox blocks, so it always answers
        // "no", which vetoes the reliable Cmd+V clipboard paste and forces
        // every insertion down to synthetic typing (silently dropped by Notes
        // and other apps). Synthetic Cmd+V works fine while sandboxed (posting
        // events is allowed), so prefer it: AlwaysPasteEligible restores the
        // Cmd+V-primary path that a non-sandboxed build would have used.
        let injector = ClipboardInjector(
            focusedTextSystem: focusedTextSystem,
            pasteEligibility: AlwaysPasteEligible(),
            chordIsHeld: ClipboardInjector.makeChordIsHeld(chord: chordProvider)
        )
        let frontmost = FrontmostApp()
        let fieldInspector = AXFocusedFieldInspector()
        self.injector = injector
        self.frontmost = frontmost

        let contextCapture = DefaultContextCaptureService(
            frontmost: frontmost,
            fieldInspector: fieldInspector
        )

        let pipeline = CapturePipeline(
            state: state,
            capture: capture,
            transcriber: transcriber,
            llm: llm,
            modes: router,
            frontmost: frontmost,
            fieldInspector: fieldInspector,
            injector: injector,
            historyStore: historyStore,
            contextCapture: contextCapture
        )
        self.pipeline = pipeline

        let pill = RecordingPillWindow()
        pillWindow = pill
        let pillActions = PillReviewActions(
            refine: { [weak self] directive in
                Task { @MainActor in await self?.pipeline?.refine(directive) }
            },
            dismiss: { [weak self] in self?.pipeline?.dismissReview() },
            hoverChanged: { [weak self] hovering in
                if hovering { self?.pipeline?.pauseReviewExpiry() }
                else { self?.pipeline?.resumeReviewExpiry() }
            }
        )
        pill.show(state: state, actions: pillActions)
    }

    private func installHotkey(state: AppState, settings: AppSettings) {
        let monitor = HotkeyMonitor()
        monitor.chord = settings.hotkeyChord
        monitor.commandModifier = settings.commandModifier
        monitor.onStartRecording = { [weak self, weak state] command in
            self?.soundPlayer?.playStart()
            self?.pipeline?.startRecording(command: command)
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
        monitor.onBeginPrewarm = { [weak self] in
            self?.pipeline?.prewarmCapture()
        }
        monitor.onCancelPrewarm = { [weak self] in
            self?.pipeline?.cancelCapturePrewarm()
        }
        // Accessibility is the hard requirement for our session-level
        // CGEventTap with .listenOnly on .flagsChanged. Input Monitoring is
        // best-effort: some macOS configurations make the tap more reliable
        // with it granted, so we trigger the prompt once at first launch but
        // do NOT gate recording on the result.
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
            state.status = .permissionsError("Hotkey monitoring requires Accessibility permission. Grant it in System Settings → Privacy & Security — Voxline will pick it up automatically.")
        }

        observeToastChanges(state: state)
        observeReviewSessionChanges(state: state)
        startPermissionAndStateLoop(state: state)

        // Startup guard: if a required permission (Accessibility / Microphone)
        // is missing, raise the permissions panel so the user gets a clear,
        // actionable prompt instead of a silently non-functional hotkey. The
        // panel polls and closes itself once the required set is granted.
        let summary = perms.summary()
        lastRequiredGranted = summary.requiredGranted
        if !summary.requiredGranted {
            permissionsWindow.show()
        }
    }

    /// Single source of truth for "should the tap be installed right now?".
    /// Centralizing the decision here prevents concurrent install/uninstall races
    /// when accessibility is revoked, hotkeyEnabled changes, and the IM watchdog
    /// all fire within the same second.
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

        // Raise the permissions panel on a granted→missing transition (runtime
        // revocation). Gated on the previous tick's state so it isn't re-raised
        // every second while permissions stay missing — which would fight a
        // user who deliberately closed it.
        let requiredGranted = (ax == .granted && perms.microphoneStatus == .granted)
        if lastRequiredGranted == true && !requiredGranted {
            permissionsWindow.show()
        }
        lastRequiredGranted = requiredGranted

        guard let monitor = hotkeyMonitor else { return }
        // Accessibility is the hard gate. Input Monitoring is informational
        // and not required to install the tap.
        let permissionsOK = (ax == .granted)
        let shouldBeInstalled = state.hotkeyEnabled && permissionsOK
        let isInstalled = monitor.isTapInstalled

        if shouldBeInstalled && !isInstalled {
            do {
                try monitor.start()
                // Clear only the permissions banner that this loop owns.
                // A pipeline or modelPrep error in flight is unrelated to
                // tap installation and must not be silently dismissed.
                if case .permissionsError = state.status {
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
                state.status = .permissionsError("Accessibility permission was revoked. Re-grant it in System Settings → Privacy & Security; Voxline will recover automatically.")
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

    /// Re-runs `pillWindow.updateVisibility` whenever `state.toastMessage`
    /// changes, so a history-row click that sets a "Copied" toast pops the
    /// pill open (and clears it on the next change, which is the auto-nil
    /// after 1.2s).
    private func observeToastChanges(state: AppState) {
        withObservationTracking {
            _ = state.toastMessage
        } onChange: { [weak self, weak state] in
            Task { @MainActor in
                guard let self, let state else { return }
                self.pillWindow?.updateVisibility(state: state)
                self.observeToastChanges(state: state)
            }
        }
    }

    /// Re-runs `pillWindow.updateVisibility` whenever `state.reviewSession`
    /// changes, so the pill flips clickable/sized when a refinement offer opens
    /// and back to click-through when it's scrubbed.
    private func observeReviewSessionChanges(state: AppState) {
        withObservationTracking {
            _ = state.reviewSession
        } onChange: { [weak self, weak state] in
            Task { @MainActor in
                guard let self, let state else { return }
                self.pillWindow?.updateVisibility(state: state)
                self.observeReviewSessionChanges(state: state)
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
                AppLog.whisper.error("model prep failed: \(error.localizedDescription)")
                if let state {
                    state.status = .error("Model setup failed: \(error.localizedDescription). Try Retry or relaunch Voxline.")
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

    private func logLaunchTrace(settings: AppSettings) {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = (info["CFBundleShortVersionString"] as? String) ?? "?"
        let build = (info["CFBundleVersion"] as? String) ?? "?"
        AppLog.pipeline.info("launch: voxline \(version) (build \(build))")
        AppLog.pipeline.info("launch: hotkey=\(settings.hotkeyChord.displayName), llm=\(settings.llmProvider.rawValue)/\(settings.llmModel), whisper=\(settings.whisperModel.rawValue)")
        let perms = PermissionsService()
        AppLog.permissions.info("launch: mic=\(String(describing: perms.microphoneStatus)), ax=\(String(describing: perms.accessibilityStatus)), im=\(String(describing: perms.inputMonitoringStatus))")
    }
}

extension AppCoordinator {
    func apply(_ snapshot: GeneralSettingsSnapshot) {
        // snapshot.provider is consumed by LLMService at the next dictation;
        // no per-snapshot action needed here.
        hotkeyMonitor?.chord = snapshot.chord
        hotkeyMonitor?.commandModifier = snapshot.commandModifier

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
