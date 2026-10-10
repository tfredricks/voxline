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
                openMainWindow: { page in
                    delegate.mainWindow.show(page)
                },
                retryLastDictation: {
                    delegate.coordinator.retryLastDictation()
                },
                startMeetingRecording: {
                    delegate.coordinator.startMeetingRecording()
                }
            )
        } label: {
            MenuBarLabel(state: delegate.appState, updateService: delegate.updateService)
        }
        .menuBarExtraStyle(.menu)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { delegate.mainWindow.show(.general) }
                    .keyboardShortcut(",")
            }
        }
    }
}

private struct MenuBarLabel: View {
    @Bindable var state: AppState
    @Bindable var updateService: UpdateService
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: MenuBarIcon.symbolName(
                for: state.status,
                paused: !state.hotkeyEnabled,
                meetingRecording: state.meetings?.phase.isRecording ?? false
            ))
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
    lazy var historyStore = DictationHistoryStore()
    let coordinator = AppCoordinator()
    lazy var learning = LearningCoordinator.live(state: appState)
    let aboutWindow = AboutWindowController()
    let historyWindow = HistoryWindowController()
    let activationPolicy = ActivationPolicyController()
    let dictationActivity = DictationActivityMonitor()
    lazy var updateService = UpdateService(dictationActivity: dictationActivity)

    lazy var mainWindow = MainWindowController { [unowned self] selection in
        AnyView(
            MainWindowView(
                selection: selection,
                home: HomeViewModel(state: appState),
                settings: makeSettingsModel()
            )
            .environment(appState)
            .environment(updateService)
        )
    }

    private func makeSettingsModel() -> SettingsModel {
        let coordinator = self.coordinator
        let generalVM = GeneralSettingsViewModel(onApply: { [weak coordinator] snapshot in
            coordinator?.apply(snapshot)
        })
        return SettingsModel(
            general: generalVM,
            apiKeys: APIKeysSettingsViewModel(onOpenAIKeyChange: { [weak coordinator] in
                coordinator?.openAIKeyDidChange()
            }),
            command: CommandSettingsViewModel(
                chords: { [weak generalVM] in generalVM?.chords ?? AppSettings().chords },
                onChange: { [weak coordinator] in coordinator?.presetsDidChange() },
                reserved: { AppSettings().meetingShortcut.map { [$0] } ?? [] }
            ),
            meetings: MeetingSettingsViewModel(
                presets: { PresetStore().load() },
                chords: { [weak generalVM] in generalVM?.chords ?? AppSettings().chords },
                onChange: { [weak coordinator] in coordinator?.meetingSettingsDidChange() }
            ),
            learning: learning,
            engineReadiness: { [weak coordinator] id in
                await coordinator?.readiness(of: id)
            }
        )
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !coordinator.bringFirstRunForward() {
            mainWindow.reopen()
        }
        return false
    }

    private var launchedAtLogin = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard !LaunchEnvironment.isRunningTests else { return }
        launchedAtLogin = LoginLaunchDetector.capture()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !LaunchEnvironment.isRunningTests else {
            AppLog.pipeline.notice("launch sequence skipped: test harness detected")
            return
        }
        activationPolicy.start()
        coordinator.learning = learning
        coordinator.presentMainWindow = { [weak self] page in self?.mainWindow.show(page) }
        coordinator.startIfNeeded(state: appState, historyStore: historyStore, launchedAtLogin: launchedAtLogin)
        _ = updateService // force-init so Sparkle's scheduler starts
        observeStatusForUpdates()
    }

    /// Mirrors the `observeHotkeyEnabledChanges` / `observePillChanges`
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
        dictationActivity.observe(status: appState.status)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard appState.meetings?.needsQuitConfirmation == true else { return .terminateNow }
        if QuitReason.endsSession(QuitReason.current) {
            AppLog.meetings.notice("quit for logout, restart, or shutdown: meeting stopped without asking")
            appState.meetings?.stop()
            return .terminateNow
        }
        let alert = NSAlert()
        alert.messageText = "Quit while a meeting is recording or being processed?"
        alert.informativeText = "The audio is saved. Voxline will offer to finish the notes the next time it opens."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        appState.meetings?.stop()
        return .terminateNow
    }

    func showAboutWindow() {
        let env = SupportEnvironment.current(
            speechEngine: coordinator.engines?.current.metricsID ?? "(unknown)"
        )
        aboutWindow.show(env: env, metrics: coordinator.pipeline?.metrics)
    }
}
