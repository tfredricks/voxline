import AppKit
import Observation
import SwiftUI

@MainActor
final class AppCoordinator {
    var hotkeyMonitor: HotkeyMonitor?
    var pipeline: CapturePipeline?
    var transcriber: TranscriptionService?
    var engines: TranscriptionEngines?
    var llm: LLMService?
    var modes: ModeRouter?
    var injector: ClipboardInjector?
    var frontmost: FrontmostApp?
    var capture: AudioCaptureService?
    var soundPlayer: HotkeySoundPlayer?

    private var pillWindow: RecordingPillWindow?
    private var escapeInterceptor: EscapeKeyInterceptor?
    private var downloadWindow: ModelDownloadWindow?
    private var modelPrepTask: Task<Void, Never>?
    /// Monotonic identity for the current modelPrepTask. The inner Task
    /// captures this value at start; the tail clears `modelPrepTask` only
    /// if its captured token still matches, preventing a late-completing
    /// task from clobbering its successor's registration.
    private var modelPrepTaskToken: UInt64 = 0
    /// True while the in-flight prep task reports into `AppState` and owns
    /// the download window (launch and wizard-retry paths). A settings-driven
    /// engine or model switch in that time inherits both, so the status is
    /// never left stuck on a cancelled task's value.
    private var modelPrepOwnsLaunchUI = false
    /// True while the in-flight prep task drives `AppState.status` (always
    /// for launch; for a settings switch, only while it reports a download).
    /// A switch in that time takes the status over.
    private var modelPrepDrivesStatus = false
    /// The engine selection last prepared for; `apply(_:)` re-prepares only
    /// when the selection changes.
    private var appliedEngine: EngineID?
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

    /// Cleans up and inserts the last dictation's transcript again, into the
    /// field focused now. Does nothing unless a transcript is retryable and
    /// the pipeline is idle or showing an error.
    func retryLastDictation() {
        guard let pipeline else { return }
        Task { await pipeline.retryLastDictation() }
    }

    func startIfNeeded(state: AppState, historyStore: DictationHistoryStore, migration: ContainerMigration.Report? = nil) {
        AXMessagingTimeout.install()
        guard !didStart else { return }
        didStart = true
        self.appState = state

        if let migration {
            AppLog.pipeline.info("container migration: prefs=\(migration.preferencesCopied) modes=\(migration.movedModes) models=\(migration.movedModelCache) ane=\(migration.movedANECache)")
            for skipped in migration.skipped {
                AppLog.pipeline.notice("container migration skipped: \(skipped, privacy: .public)")
            }
            for failure in migration.failures {
                AppLog.pipeline.error("container migration failed: \(failure, privacy: .public)")
            }
        }

        let settings = AppSettings()
        logLaunchTrace(settings: settings)
        if !settings.hasCompletedFirstRun {
            startWizardThenApp(state: state, settings: settings, historyStore: historyStore)
        } else {
            startApp(state: state, settings: settings, historyStore: historyStore)
        }

        if let migration, !migration.failures.isEmpty {
            flashToast("Couldn't move old data — see log", state: state)
        }
    }

    private func flashToast(_ message: String, state: AppState) {
        state.toastMessage = message
        Task { @MainActor [weak state] in
            try? await Task.sleep(for: .seconds(4))
            if state?.toastMessage == message { state?.toastMessage = nil }
        }
    }

    private func startWizardThenApp(state: AppState, settings: AppSettings, historyStore: DictationHistoryStore) {
        buildServices(state: state, settings: settings, historyStore: historyStore)
        guard let engine = engines?.current else { return }

        let wizard = FirstRunWindowController()
        self.firstRunWindow = wizard
        Task { @MainActor [weak self] in
            await wizard.show(
                state: state,
                settings: settings,
                engine: engine,
                chord: settings.hotkeyChord,
                onRetryDownload: { [weak self, weak state] in
                    guard let self, let state, let engine = self.engines?.current else { return }
                    self.prepareIfNeeded(state: state, engine: engine)
                },
                onComplete: { [weak self] in
                    guard let self else { return }
                    self.firstRunWindow = nil
                    self.installHotkey(state: state, settings: settings)
                }
            )
        }

        // Eagerly start preparing the engine so by the time the user reaches
        // the speech-engine step, progress is already advancing.
        prepareIfNeeded(state: state, engine: engine)
    }

    private func startApp(state: AppState, settings: AppSettings, historyStore: DictationHistoryStore) {
        buildServices(state: state, settings: settings, historyStore: historyStore)
        guard let engine = engines?.current else { return }
        installHotkey(state: state, settings: settings)
        prepareIfNeeded(state: state, engine: engine)
    }

    private func buildServices(state: AppState, settings: AppSettings, historyStore: DictationHistoryStore) {
        let capture = AudioCaptureService()
        self.capture = capture
        self.soundPlayer = HotkeySoundPlayer(settings: settings)
        let transcriber = TranscriptionService(model: settings.whisperModel)
        self.transcriber = transcriber
        let engines = TranscriptionEngines(
            settings: settings,
            apple: AppleSpeechEngine(),
            whisperKit: WhisperKitEngine(service: transcriber)
        )
        self.engines = engines
        self.appliedEngine = settings.transcriptionEngine

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
        let commandModifierProvider: @Sendable () -> HotkeyChord.Modifier? = { AppSettings().commandModifier }
        let injector = ClipboardInjector(
            focusedTextSystem: focusedTextSystem,
            chordIsHeld: ClipboardInjector.makeChordIsHeld(chord: chordProvider, command: commandModifierProvider)
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
            engines: engines,
            llm: llm,
            modes: router,
            frontmost: frontmost,
            fieldInspector: fieldInspector,
            injector: injector,
            historyStore: historyStore,
            contextCapture: contextCapture,
            selectionSnapshot: AXSelectionReader()
        )
        self.pipeline = pipeline
        capture.onInterrupted = { [weak pipeline] in pipeline?.handleCaptureInterrupted() }

        let pill = RecordingPillWindow()
        pillWindow = pill
        pill.show(state: state)
        observeToastChanges(state: state)
        observePillContentChanges(state: state)
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
            if self?.pipeline?.wasCancelled != true {
                self?.soundPlayer?.playStop()
            }
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
        monitor.onMaxDurationReached = { [weak self, weak state] in
            guard state?.status == .recording else { return }
            self?.pipeline?.capHit = true
        }
        escapeInterceptor = EscapeKeyInterceptor(onEscape: { [weak self, weak state] in
            self?.pipeline?.cancel()
            if let state { self?.pillWindow?.updateVisibility(state: state) }
        })
        pillWindow?.onRetry = { [weak self] in self?.retryLastDictation() }
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
        // use but it's unreliable — it silently records zeros
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
        reconcileEscapeInterceptor(state: state)
        observeCancellableChanges(state: state)

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
        reconcileEscapeInterceptor(state: state)
    }

    /// Keeps the Esc tap installed exactly while the hotkey tap is. A tap
    /// that can't be created leaves Esc cancel unavailable and is retried on
    /// the next tick.
    private func reconcileEscapeInterceptor(state: AppState) {
        guard let interceptor = escapeInterceptor, let monitor = hotkeyMonitor else { return }
        if monitor.isTapInstalled && !interceptor.isInstalled {
            if interceptor.install() {
                syncEscapeInterceptor(state: state)
            }
        } else if !monitor.isTapInstalled && interceptor.isInstalled {
            interceptor.uninstall()
        }
    }

    /// Arms Esc while the pipeline can cancel, letting it through with the
    /// hotkey's own modifiers held, since the chord is down while recording.
    private func syncEscapeInterceptor(state: AppState) {
        guard let interceptor = escapeInterceptor else { return }
        if let monitor = hotkeyMonitor {
            let held = [monitor.chord.modifierA, monitor.chord.modifierB] + [monitor.commandModifier].compactMap { $0 }
            interceptor.hotkeyModifiers = EscapeKeyInterceptor.modifierFlags(of: held)
        }
        interceptor.isArmed = state.isCancellable
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

    private func observeCancellableChanges(state: AppState) {
        withObservationTracking {
            _ = state.isCancellable
        } onChange: { [weak self, weak state] in
            Task { @MainActor in
                guard let self, let state else { return }
                self.syncEscapeInterceptor(state: state)
                self.observeCancellableChanges(state: state)
            }
        }
    }

    /// Re-runs `pillWindow.updateVisibility` whenever the live transcript,
    /// pipeline phase, or status changes, so the pill grows to show text as
    /// soon as the first partial arrives and re-anchors bottom-center.
    private func observePillContentChanges(state: AppState) {
        withObservationTracking {
            _ = state.liveTranscript
            _ = state.pipelinePhase
            _ = state.status
        } onChange: { [weak self, weak state] in
            Task { @MainActor in
                guard let self, let state else { return }
                self.pillWindow?.updateVisibility(state: state)
                self.observePillContentChanges(state: state)
            }
        }
    }

    private func prepareIfNeeded(state: AppState, engine: any TranscriptionEngine) {
        runModelPrepTask(state: state, engine: engine, audience: .launch)
    }

    /// Readiness of the engine that runs for `id`, or nil before services exist.
    func readiness(of id: EngineID) async -> EngineReadiness? {
        guard let engines else { return nil }
        return await engines.engine(for: id).readiness()
    }

    /// Single-flight readiness check + prepare. Cancels any in-flight task
    /// before starting a new one so a settings-driven engine or model switch
    /// during launch prep doesn't race against the launch-path prepareIfNeeded.
    ///
    /// The plan comes from `engine.readiness()`; `EnginePrep.status(for:audience:current:)`
    /// decides whether the task reports it through `state.status` (download
    /// progress → preparing → idle, or the failure), and
    /// `EnginePrep.showsDownloadWindow(for:audience:)` whether the download
    /// window opens. A task that doesn't report stays silent throughout.
    ///
    /// - Parameters:
    ///   - state: `AppState` the task may report into.
    ///   - engine: The engine to bring to ready.
    ///   - audience: `.launch` for the launch path, wizard retry, or a switch
    ///     that takes their place (the only audience that manages the download
    ///     window); otherwise from `EnginePrep.Audience.forSwitch`.
    private func runModelPrepTask(
        state: AppState?,
        engine: any TranscriptionEngine,
        audience: EnginePrep.Audience
    ) {
        modelPrepTask?.cancel()
        modelPrepTaskToken &+= 1
        let myToken = modelPrepTaskToken
        let managesDownloadWindow = audience == .launch
        modelPrepOwnsLaunchUI = managesDownloadWindow
        modelPrepDrivesStatus = audience.ownsStatusFromStart
        // A status-owning task resets the status right away so a stale value
        // (an error being retried, or an inherited
        // `.downloadingModel(progress: 0.37)` from a cancelled task) doesn't
        // linger while readiness is checked.
        if let state, audience.ownsStatusFromStart {
            state.status = .preparingModel
        }
        modelPrepTask = Task { @MainActor [weak self, weak state] in
            var reporter: AppState?
            do {
                let plan = EnginePrep.plan(for: await engine.readiness())
                try Task.checkCancellation()
                if let state, let status = EnginePrep.status(for: plan, audience: audience, current: state.status) {
                    state.status = status
                    reporter = state
                }
                self?.modelPrepDrivesStatus = reporter != nil
                if case .fail(let reason) = plan {
                    AppLog.pipeline.error("engine \(engine.id.rawValue, privacy: .public) unavailable: \(reason, privacy: .public)")
                    if managesDownloadWindow {
                        self?.closeDownloadWindow()
                    }
                    self?.finishModelPrepTask(token: myToken)
                    return
                }
                if EnginePrep.showsDownloadWindow(for: plan, audience: audience), let state {
                    self?.showDownloadWindow(state: state)
                }
                let progressReporter = reporter
                try await engine.prepare { progress in
                    Task { @MainActor in
                        guard self?.isCurrentPrepTask(myToken) == true,
                              let progressReporter,
                              case .downloadingModel = progressReporter.status else { return }
                        progressReporter.status = progress >= 1 ? .preparingModel : .downloadingModel(progress: progress)
                    }
                }
                try Task.checkCancellation()
                if let reporter, reporter.status.blocksRecording {
                    reporter.status = .idle
                }
                if managesDownloadWindow {
                    self?.closeDownloadWindow()
                }
            } catch is CancellationError {
                // A newer prep task superseded this one. Don't surface as a
                // user-facing error.
                return
            } catch {
                // A cancelled download can surface as an ordinary error
                // (`URLError(.cancelled)`); a superseded task must not report it.
                guard self?.isCurrentPrepTask(myToken, cancelled: Task.isCancelled) == true else { return }
                AppLog.pipeline.error("engine \(engine.id.rawValue, privacy: .public) prep failed: \(error.localizedDescription)")
                if let reporter {
                    reporter.status = .error("Model setup failed: \(error.localizedDescription). Try Retry or relaunch Voxline.")
                }
                if managesDownloadWindow {
                    self?.closeDownloadWindow()
                }
            }
            self?.finishModelPrepTask(token: myToken)
        }
    }

    private func isCurrentPrepTask(_ token: UInt64, cancelled: Bool = false) -> Bool {
        EnginePrep.isCurrentTask(token: token, latestToken: modelPrepTaskToken, isCancelled: cancelled)
    }

    /// Only clears the registration if no newer task has replaced this one.
    /// Without this guard, a late-finishing prior task would null out the
    /// successor's registration, leaving it unreachable for cancel().
    private func finishModelPrepTask(token: UInt64) {
        guard modelPrepTaskToken == token else { return }
        modelPrepTask = nil
        modelPrepOwnsLaunchUI = false
        modelPrepDrivesStatus = false
    }

    private func showDownloadWindow(state: AppState) {
        let window = downloadWindow ?? ModelDownloadWindow()
        downloadWindow = window
        window.show(state: state)
    }

    private func closeDownloadWindow() {
        downloadWindow?.close()
        downloadWindow = nil
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
        AppLog.pipeline.info("launch: hotkey=\(settings.hotkeyChord.displayName), llm=\(settings.llmProvider.rawValue)/\(settings.llmModel), engine=\(settings.transcriptionEngine.rawValue), whisper=\(settings.whisperModel.rawValue)")
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

        guard let engines else { return }
        let engineChanged = snapshot.engine != appliedEngine
        appliedEngine = snapshot.engine
        let selected = engines.engine(for: snapshot.engine)

        // Switching Whisper model invalidates the loaded pipeline; the next
        // transcribe re-loads from the (possibly cached) new variant.
        var whisperModelChanged = false
        if let transcriber, transcriber.model != snapshot.whisperModel {
            transcriber.model = snapshot.whisperModel
            whisperModelChanged = true
        }

        // A new engine, or a new model for the selected WhisperKit engine,
        // gets a single-flight background prepare so the user doesn't pay
        // for it on the next dictation. `engines.current` already follows
        // the setting. Shares modelPrepTask with the launch path so a
        // mid-prep switch cancels cleanly.
        guard engineChanged || (whisperModelChanged && selected.id == .whisperKit) else { return }
        // Take over whatever the in-flight prep owns (launch UI, or a status
        // it is driving) so the status never freezes at a cancelled task's
        // value. Otherwise a download is reported in the status without the
        // window, and a warm-up is silent.
        runModelPrepTask(
            state: appState,
            engine: selected,
            audience: .forSwitch(inFlightOwnsLaunchUI: modelPrepOwnsLaunchUI, inFlightDrivesStatus: modelPrepDrivesStatus)
        )
    }
}
