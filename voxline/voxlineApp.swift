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
                },
                retryLastDictation: {
                    delegate.coordinator.retryLastDictation()
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
                apiKeysVM: APIKeysSettingsViewModel(onOpenAIKeyChange: { [weak coordinator = delegate.coordinator] in
                    coordinator?.openAIKeyDidChange()
                }),
                engineReadiness: { [weak coordinator = delegate.coordinator] id in
                    await coordinator?.readiness(of: id)
                }
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
    lazy var historyStore = DictationHistoryStore()
    let coordinator = AppCoordinator()
    let aboutWindow = AboutWindowController()
    let historyWindow = HistoryWindowController()
    let windowVisibility = WindowVisibilityCoordinator()
    let dictationActivity = DictationActivityMonitor()
    lazy var updateService = UpdateService(dictationActivity: dictationActivity)

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !LaunchEnvironment.isRunningTests else {
            AppLog.pipeline.notice("launch sequence skipped: test harness detected")
            return
        }
        let migration = ContainerMigration.standard()?.runIfNeeded()
        windowVisibility.start()
        coordinator.startIfNeeded(state: appState, historyStore: historyStore, migration: migration)
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
            speechEngine: coordinator.engines?.current.metricsID ?? "(unknown)"
        )
        aboutWindow.show(env: env, metrics: coordinator.pipeline?.metrics)
    }
}
