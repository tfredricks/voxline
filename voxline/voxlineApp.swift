// voxline/voxlineApp.swift  (replace contents)
import AppKit
import SwiftUI

@main
struct voxlineApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(state: delegate.appState)
        } label: {
            MenuBarLabel(state: delegate.appState)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        coordinator.startIfNeeded(state: appState)
    }
}

@MainActor
final class AppCoordinator {
    private var hotkeyMonitor: HotkeyMonitor?
    private var pillWindow: RecordingPillWindow?
    private var downloadWindow: ModelDownloadWindow?
    private var pipeline: CapturePipeline?
    private var transcriber: TranscriptionService?
    private var didStart = false
    private var accessibilityRetryTimer: Timer?

    func startIfNeeded(state: AppState) {
        guard !didStart else { return }
        didStart = true

        let capture = AudioCaptureService()
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
        let llm = LLMService(settings: AppSettings(), keychain: Keychain())

        // Output
        let injector = ClipboardInjector()
        let frontmost = FrontmostApp()

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

        let monitor = HotkeyMonitor()
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
        do {
            try monitor.start()
            hotkeyMonitor = monitor
        } catch {
            // Accessibility wasn't granted yet. Macos doesn't deliver a
            // permission-changed notification to the running process, so
            // poll until it's granted and then install the tap. The user
            // does NOT need to restart the app.
            state.status = .error("Hotkey monitoring requires Accessibility permission. Grant it in System Settings → Privacy & Security → Accessibility — voxline will pick it up automatically.")
            startAccessibilityRetry(state: state, monitor: monitor)
        }

        prepareIfNeeded(state: state, transcriber: transcriber)
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

    private func prepareIfNeeded(state: AppState, transcriber: TranscriptionService) {
        let needsDownload = !TranscriptionService.isModelCached(transcriber.model)
        state.status = needsDownload ? .downloadingModel(progress: 0) : .preparingModel
        let window = ModelDownloadWindow()
        downloadWindow = window
        window.show(state: state)

        Task { @MainActor in
            do {
                if needsDownload {
                    try await transcriber.prepareModel { progress in
                        Task { @MainActor in
                            if case .downloadingModel = state.status {
                                state.status = .downloadingModel(progress: progress)
                            }
                        }
                    }
                    if case .downloadingModel = state.status {
                        state.status = .preparingModel
                    }
                }
                try await transcriber.prewarm()
                if case .preparingModel = state.status {
                    state.status = .idle
                }
                downloadWindow?.close()
                downloadWindow = nil
            } catch {
                state.status = .error("Model setup failed: \(error.localizedDescription). Quit and relaunch voxline to retry.")
                downloadWindow?.close()
                downloadWindow = nil
            }
        }
    }
}
