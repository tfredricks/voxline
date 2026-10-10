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
    var inserter: TextInserter?
    var frontmost: FrontmostApp?
    var capture: AudioCaptureService?
    var soundPlayer: HotkeySoundPlayer?
    /// Set by the app delegate before `startIfNeeded`.
    var learning: LearningCoordinator?

    private var pillWindow: RecordingPillWindow?
    private var keyInterceptor: KeyInterceptor?
    private let meetingTimer = MeetingTimerPanel()
    private var meetingNotifier: UserNotificationMeetingNotifier?
    private var retentionTimer: Timer?
    private let presetStore = PresetStore()
    private var presetMap: [KeyCombo: UUID] = [:]
    private var frontmostObserver: NSObjectProtocol?
    private var shortcutCaptureSuspender: ShortcutCaptureSuspender?
    private var downloadWindow: ModelDownloadWindow?
    private var modelPrepTask: Task<Void, Never>?
    /// Monotonic identity for the current modelPrepTask. The inner Task
    /// captures this value at start; the tail clears `modelPrepTask` only
    /// if its captured token still matches, preventing a late-completing
    /// task from clobbering its successor's registration.
    private var modelPrepTaskToken: UInt64 = 0
    /// True while the in-flight prep task reports into `AppState` and owns
    /// the download window (the launch path). A settings-driven engine or
    /// model switch in that time inherits both, so the status is never left
    /// stuck on a cancelled task's value.
    private var modelPrepOwnsLaunchUI = false
    /// True while the in-flight prep task drives `AppState.status` (always
    /// for launch and the wizard; for a settings switch, only while it
    /// reports a download).
    /// A switch in that time takes the status over.
    private var modelPrepDrivesStatus = false
    /// The `.error` message a prep task last wrote, while it may still be
    /// showing. A later prep whose engine is ready clears exactly this error
    /// (see `EnginePrep.clearsStaleError`), never a pipeline error.
    private var lastPrepError: String?
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
    /// Tracks the required-permission state across reconcile ticks so we can
    /// open Home on a granted→missing transition (runtime revocation)
    /// without reopening it every tick while it stays missing.
    private var lastRequiredGranted: Bool?
    /// The capture engine binds its input device once, as soon as the
    /// microphone is granted, so the first keypress after launch doesn't.
    private var didWarmUpCapture = false

    /// Brings up the main window; set by `AppDelegate` before `startIfNeeded`.
    var presentMainWindow: (MainWindowPage) -> Void = { _ in }

    /// Starts a meeting recording, or opens Home instead
    /// when the microphone isn't allowed. The notification permission prompt
    /// waits for the first recording that actually starts.
    func startMeetingRecording() {
        guard let meetings = appState?.meetings else { return }
        guard PermissionsService().microphoneStatus == .granted else {
            AppLog.meetings.notice("meeting start blocked: microphone not allowed")
            presentMainWindow(.home)
            return
        }
        meetings.start()
        if meetings.phase.isRecording {
            meetingNotifier?.requestAuthorization()
        }
    }

    /// The meeting shortcut: starts like `startMeetingRecording()` when
    /// idle, stops while recording, and does nothing while processing.
    func toggleMeetingRecording() {
        guard let meetings = appState?.meetings else { return }
        if meetings.phase == .idle {
            startMeetingRecording()
        } else {
            meetings.toggle()
        }
    }

    /// Brings the first-run wizard forward while it runs, so nothing opens
    /// over it; false once it has completed (or never ran).
    func bringFirstRunForward() -> Bool {
        guard let firstRunWindow else { return false }
        firstRunWindow.bringForward()
        return true
    }

    /// Cleans up and inserts the last dictation's transcript again, into the
    /// field focused now. Does nothing unless a transcript is retryable and
    /// the pipeline is idle or showing an error.
    func retryLastDictation() {
        guard let pipeline else { return }
        Task { await pipeline.retryLastDictation() }
    }

    func startIfNeeded(state: AppState, historyStore: DictationHistoryStore, launchedAtLogin: Bool = false) {
        AXMessagingTimeout.install()
        guard !didStart else { return }
        didStart = true
        self.appState = state

        let settings = AppSettings()
        logLaunchTrace(settings: settings)
        let presentation = LaunchPresentation.decide(
            firstRunComplete: settings.hasCompletedFirstRun,
            requiredPermissionsGranted: PermissionsService().summary().requiredGranted,
            launchedAtLogin: launchedAtLogin
        )
        AppLog.pipeline.info("launch presentation: \(String(describing: presentation), privacy: .public)")
        switch presentation {
        case .wizard:
            startWizardThenApp(state: state, settings: settings, historyStore: historyStore)
        case .home:
            startApp(state: state, settings: settings, historyStore: historyStore)
            presentMainWindow(.home)
        case .none:
            startApp(state: state, settings: settings, historyStore: historyStore)
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
                onRetryDownload: { [weak self] in
                    guard let self, let engine = self.engines?.current else { return }
                    self.runModelPrepTask(state: state, engine: engine, audience: .wizard)
                },
                onComplete: { [weak self] in
                    guard let self else { return }
                    self.firstRunWindow = nil
                    self.installHotkey(state: state, settings: settings)
                    self.presentMainWindow(.home)
                }
            )
        }

        // Eagerly start preparing the engine so by the time the user reaches
        // the speech-engine step, progress is already advancing.
        runModelPrepTask(state: state, engine: engine, audience: .wizard)
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
            whisperKit: WhisperKitEngine(service: transcriber),
            openAI: OpenAIRealtimeEngine(keychain: DataProtectionKeychain())
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
        let paste = PasteInjector()
        let inserter = TextInserter(paste: paste)
        let frontmost = FrontmostApp()
        let fieldInspector = AXFocusedFieldInspector()
        self.inserter = inserter
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
            inserter: inserter,
            historyStore: historyStore,
            contextCapture: contextCapture,
            selectionSnapshot: DefaultSelectionSnapshot(),
            editContextReader: EditContextReader(),
            learning: learning
        )
        self.pipeline = pipeline
        capture.onInterrupted = { [weak pipeline] in pipeline?.handleCaptureInterrupted() }
        // The start cue plays once the first tap buffer is in, so hearing it
        // means the mic is capturing; played on the keypress it led the mic
        // by ~200 ms on a cold engine, and the first word's onset was lost.
        pipeline.onRecordingStarted = { [weak self] in self?.soundPlayer?.playStart() }
        soundPlayer?.prime()

        let pill = RecordingPillWindow()
        pillWindow = pill
        pill.show(state: state)
        observeToastChanges(state: state)
        observePillContentChanges(state: state)
        buildMeetings(state: state, settings: settings)
    }

    private func installHotkey(state: AppState, settings: AppSettings) {
        let monitor = HotkeyMonitor()
        monitor.chords = settings.chords
        monitor.onStartRecording = { [weak self, weak state] kind in
            self?.pipeline?.startRecording(kind: kind)
            if let state { self?.pillWindow?.updateVisibility(state: state) }
        }
        monitor.onFinalizeRecording = { [weak self, weak state] _ in
            if self?.pipeline?.wasCancelled != true {
                self?.soundPlayer?.playStop()
            }
            Task { @MainActor in
                await self?.pipeline?.finalizeRecording()
                self?.hotkeyMonitor?.recordingFinished()
                if let state { self?.pillWindow?.updateVisibility(state: state) }
            }
        }
        monitor.onDiscardRecording = { [weak self, weak state] _ in
            self?.pipeline?.cancel(reason: .shortcut)
            self?.hotkeyMonitor?.recordingFinished()
            if let state { self?.pillWindow?.updateVisibility(state: state) }
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
        keyInterceptor = KeyInterceptor(
            onEscape: { [weak self, weak state] in
                self?.pipeline?.cancel()
                if let state { self?.pillWindow?.updateVisibility(state: state) }
            },
            onPreset: { [weak self] id in
                guard let self else { return }
                self.hotkeyMonitor?.noteSwallowedKeyDown()
                guard let preset = self.presetStore.load().first(where: { $0.id == id }) else { return }
                Task { await self.pipeline?.runPreset(preset) }
            },
            onMeeting: { [weak self] in
                self?.hotkeyMonitor?.noteSwallowedKeyDown()
                self?.toggleMeetingRecording()
            }
        )
        presetMap = KeyInterceptor.presetMap(presetStore.load())
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

        // The reconcile loop owns the monitor from here. macOS doesn't tell a
        // running process when Accessibility is granted, so without it the
        // loop shows the missing permission and installs the tap once it
        // polls a grant; the user does NOT need to restart the app.
        hotkeyMonitor = monitor
        reconcileTap(state: state, axGranted: perms.accessibilityStatus == .granted)
        observeCancellableChanges(state: state)
        observeFrontmostApp()
        shortcutCaptureSuspender = ShortcutCaptureSuspender(
            state: state,
            suspend: { [weak self] in
                self?.hotkeyMonitor?.suspend()
                self?.refreshInterceptorConfig()
            },
            resume: { [weak self] in
                self?.hotkeyMonitor?.resume()
                self?.refreshInterceptorConfig()
            }
        )

        startPermissionAndStateLoop(state: state)

        let summary = perms.summary()
        lastRequiredGranted = summary.requiredGranted
    }

    /// Single source of truth for "should the tap be installed right now?".
    /// Centralizing the decision here prevents concurrent install/uninstall races
    /// when accessibility is revoked, hotkeyEnabled changes, and the IM watchdog
    /// all fire within the same second.
    private func startPermissionAndStateLoop(state: AppState) {
        permissionPollTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self, weak state] _ in
            MainActor.assumeIsolated {
                guard let self, let state else { return }
                self.reconcileTapWithPermissionsAndEnabled(state: state)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        permissionPollTimer = timer
        // React instantly to user-driven hotkeyEnabled toggles instead of
        // waiting up to 1s for the next poll tick.
        observeHotkeyEnabledChanges(state: state)
    }

    private func reconcileTapWithPermissionsAndEnabled(state: AppState) {
        let perms = PermissionsService()
        let ax = perms.accessibilityStatus

        // Open Home on a granted→missing transition (runtime
        // revocation). Gated on the previous tick's state so the main window
        // isn't reopened every second while permissions stay missing — which
        // would fight a user who deliberately closed it.
        let microphoneGranted = perms.microphoneStatus == .granted
        let requiredGranted = (ax == .granted && microphoneGranted)
        if lastRequiredGranted == true && !requiredGranted {
            presentMainWindow(.home)
        }
        lastRequiredGranted = requiredGranted
        if microphoneGranted && !didWarmUpCapture {
            didWarmUpCapture = true
            capture?.warmUp()
        }

        reconcileTap(state: state, axGranted: ax == .granted)
    }

    /// Installs or removes the hotkey tap and sets the permissions status as
    /// `TapReconcile` decides, then brings the key interceptor in line.
    private func reconcileTap(state: AppState, axGranted: Bool) {
        guard let monitor = hotkeyMonitor else { return }
        let decision = TapReconcile.decide(
            hotkeyEnabled: state.hotkeyEnabled,
            axGranted: axGranted,
            isInstalled: monitor.isTapInstalled,
            status: state.status
        )
        var applied = true
        switch decision.tap {
        case .install:
            do {
                try monitor.start()
            } catch {
                // tapCreate can lag behind AXIsProcessTrusted; retry next tick.
                applied = false
            }
        case .uninstall:
            monitor.stop()
        case .keep:
            break
        }
        if applied, let status = decision.status {
            state.status = status
        }
        reconcileKeyInterceptor()
    }

    /// Keeps the key interceptor installed exactly while the hotkey tap is.
    /// A tap that can't be created leaves Esc cancel and presets unavailable
    /// and is retried, at most every `KeyInterceptor.installRetryInterval`.
    private func reconcileKeyInterceptor() {
        guard let interceptor = keyInterceptor, let monitor = hotkeyMonitor else { return }
        if monitor.isTapInstalled && !interceptor.isInstalled {
            interceptor.install()
        } else if !monitor.isTapInstalled && interceptor.isInstalled {
            interceptor.uninstall()
        }
        refreshInterceptorConfig()
    }

    /// Arms Esc while the pipeline can cancel, letting it through with either
    /// chord's modifiers held, and arms presets while the tap is installed,
    /// no shortcut is being recorded, and voxline isn't frontmost.
    private func refreshInterceptorConfig(activated: NSRunningApplication? = nil) {
        guard let interceptor = keyInterceptor, let state = appState else { return }
        let frontmost = activated ?? NSWorkspace.shared.frontmostApplication
        let voxlineIsFrontmost = frontmost?.bundleIdentifier == Bundle.main.bundleIdentifier
        let presetsArmed = KeyInterceptor.presetsArmed(
            installed: interceptor.isInstalled,
            capturingShortcut: state.shortcutCaptureDepth > 0,
            voxlineIsFrontmost: voxlineIsFrontmost
        )
        interceptor.config = KeyInterceptor.Config(
            escapeArmed: state.isCancellable,
            presetsArmed: presetsArmed,
            presets: presetMap,
            chordFamilies: hotkeyMonitor?.chords.families ?? [],
            meetingArmed: presetsArmed,
            meetingToggle: AppSettings().meetingShortcut
        )
    }

    /// Settings → Commands saved the presets.
    func presetsDidChange() {
        presetMap = KeyInterceptor.presetMap(presetStore.load())
        refreshInterceptorConfig()
    }

    /// Settings → Meetings changed the shortcut, timer, or other settings.
    func meetingSettingsDidChange() {
        refreshInterceptorConfig()
        if let state = appState { updateMeetingTimer(state: state) }
    }

    private func buildMeetings(state: AppState, settings: AppSettings) {
        let store: MeetingStore
        do {
            store = try MeetingStore.standard()
        } catch {
            AppLog.meetings.error("meetings unavailable: \(error.localizedDescription, privacy: .public)")
            return
        }
        let notifier = UserNotificationMeetingNotifier()
        meetingNotifier = notifier
        let vocabulary = CustomVocabularyStore()
        let pipeline = MeetingPipeline(
            store: store,
            transcriber: WhisperMeetingTranscriber(model: { .smallEn }),
            diarizer: SpeakerKitDiarizer(),
            notes: LLMService.meetingNotesService(settings: settings),
            transcoder: AACTranscoder(),
            settings: {
                let current = AppSettings()
                return MeetingPipelineSettings(
                    notesFolder: current.meetingNotesFolder,
                    notesModel: current.resolvedMeetingNotesModel,
                    vocabulary: vocabulary.load(),
                    retention: current.meetingAudioRetention,
                    modelsNeedDownload: !TranscriptionService.isModelCached(.smallEn)
                )
            }
        )
        let controller = MeetingController(
            store: store,
            settings: settings,
            makeRecorder: { directory, observer in
                let current = AppSettings()
                return MeetingRecorder(
                    mic: MicMeetingSource(preferredInputDeviceUID: current.audioInputDeviceUID),
                    system: SystemAudioTap(),
                    directory: directory,
                    cap: current.meetingCapSeconds.map { .seconds($0) } ?? MeetingRecorder.defaultCap,
                    observer: observer
                )
            },
            makeLiveTranscript: { [weak self] in
                guard AppSettings().liveTranscriptEnabled, let engine = self?.engines?.engine(for: .apple) else { return nil }
                return LiveMeetingTranscript(engine: engine)
            },
            pipeline: pipeline,
            notifier: notifier,
            prompts: AlertMeetingPrompts()
        )
        state.meetings = controller
        controller.applyRetention()
        retentionTimer = Timer.scheduledTimer(withTimeInterval: 86_400, repeats: true) { [weak controller] _ in
            MainActor.assumeIsolated { controller?.applyRetention() }
        }
        observeMeetingPhase(state: state)
        Task { await controller.recoverUnfinished() }
    }

    private func observeMeetingPhase(state: AppState) {
        withObservationTracking {
            _ = state.meetings?.phase
        } onChange: { [weak self, weak state] in
            Task { @MainActor in
                guard let self, let state else { return }
                self.updateMeetingTimer(state: state)
                self.observeMeetingPhase(state: state)
            }
        }
        updateMeetingTimer(state: state)
    }

    private func updateMeetingTimer(state: AppState) {
        if case .recording(let startedAt) = state.meetings?.phase, AppSettings().showMeetingTimer {
            meetingTimer.show(startedAt: startedAt, live: state.meetings?.liveTranscript)
        } else {
            meetingTimer.hide()
        }
    }

    private func observeFrontmostApp() {
        guard frontmostObserver == nil else { return }
        frontmostObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let activated = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.refreshInterceptorConfig(activated: activated) }
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
    /// changes, so a toast (such as "Copied" after a history-row click) pops
    /// the pill open, and the pill hides again when `flashToast` clears it.
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
                self.refreshInterceptorConfig()
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

    /// The saved OpenAI key changed. With the OpenAI engine selected, its
    /// readiness is checked again, so saving a key clears the missing-key
    /// error and clearing the key shows it.
    func openAIKeyDidChange() {
        guard let engines, EnginePrep.rechecksAfterOpenAIKeyChange(selected: engines.current.id) else { return }
        if let appState, EnginePrep.isOpenAIKeyError(appState.status) {
            appState.status = .idle
        }
        runModelPrepTask(
            state: appState,
            engine: engines.current,
            audience: .forSwitch(inFlightOwnsLaunchUI: modelPrepOwnsLaunchUI, inFlightDrivesStatus: modelPrepDrivesStatus)
        )
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
    ///   - audience: `.launch` for the launch path or a switch that takes its
    ///     place (the only audience that manages the download window);
    ///     `.wizard` for the first-run wizard and its Retry; otherwise from
    ///     `EnginePrep.Audience.forSwitch`.
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
        lastPrepError = EnginePrep.prepErrorStillShowing(lastPrepError, current: state?.status)
        modelPrepTask = Task { @MainActor [weak self, weak state] in
            var reporter: AppState?
            do {
                let plan = EnginePrep.plan(for: await engine.readiness())
                try Task.checkCancellation()
                if let state, EnginePrep.clearsStaleError(plan: plan, current: state.status, lastPrepError: self?.lastPrepError) {
                    state.status = .idle
                    self?.lastPrepError = nil
                }
                if let state, let status = EnginePrep.status(for: plan, audience: audience, current: state.status) {
                    state.status = status
                    reporter = state
                    self?.lastPrepError = status.errorMessage
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
                self?.lastPrepError = nil
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
                    let message = "Model setup failed: \(error.localizedDescription). Try Retry or relaunch Voxline."
                    reporter.status = .error(message)
                    self?.lastPrepError = message
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
        if let frontmostObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(frontmostObserver)
        }
    }

    private func logLaunchTrace(settings: AppSettings) {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = (info["CFBundleShortVersionString"] as? String) ?? "?"
        let build = (info["CFBundleVersion"] as? String) ?? "?"
        AppLog.pipeline.info("launch: voxline \(version) (build \(build))")
        AppLog.pipeline.info("launch: hotkey=\(settings.hotkeyChord.displayName), command=\(settings.commandChord?.displayName ?? "off"), llm=\(settings.llmProvider.rawValue)/\(settings.llmModel), engine=\(settings.transcriptionEngine.rawValue), whisper=\(settings.whisperModel.rawValue)")
        let perms = PermissionsService()
        AppLog.permissions.info("launch: mic=\(String(describing: perms.microphoneStatus)), ax=\(String(describing: perms.accessibilityStatus)), im=\(String(describing: perms.inputMonitoringStatus))")
    }
}

extension AppCoordinator {
    func apply(_ snapshot: GeneralSettingsSnapshot) {
        // snapshot.provider is consumed by LLMService at the next dictation;
        // no per-snapshot action needed here.
        hotkeyMonitor?.chords = ChordSet(dictation: snapshot.chord, command: snapshot.commandChord)
        refreshInterceptorConfig()

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
