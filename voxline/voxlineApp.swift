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

        // PLAN 2 ONLY — Window scene removed in Plan 3 once paste replaces
        // the debug verification UI.
        Window("voxline — Transcripts (debug)", id: "debug-transcripts") {
            DebugTranscriptWindow(state: delegate.appState)
        }
        .defaultSize(width: 520, height: 360)
    }
}

/// Menu-bar icon view. `@Bindable` makes it re-render as AppState.status changes.
private struct MenuBarLabel: View {
    @Bindable var state: AppState
    var body: some View {
        Image(systemName: MenuBarIcon.symbolName(for: state.status))
    }
}

/// Owns the AppState + AppCoordinator and triggers coordinator startup at
/// app launch via applicationDidFinishLaunching. Using NSApplicationDelegate
/// rather than `.task` on the MenuBarExtra label, which is unreliable in
/// macOS for menu-bar-only apps.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    let coordinator = AppCoordinator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        coordinator.startIfNeeded(state: appState)
    }
}

/// Owns the long-lived runtime objects (HotkeyMonitor, AudioCapture,
/// TranscriptionService, CapturePipeline, RecordingPillWindow,
/// ModelDownloadWindow) and starts them at app launch.
@MainActor
final class AppCoordinator {
    private var hotkeyMonitor: HotkeyMonitor?
    private var pillWindow: RecordingPillWindow?
    private var downloadWindow: ModelDownloadWindow?
    private var pipeline: CapturePipeline?
    private var transcriber: TranscriptionService?
    private var didStart = false
    // Reserved for Plan 3 — will hold an Observation token once
    // AppState.audioLevel drives the menu-bar icon animation.
    private var levelObservation: AnyObject?

    func startIfNeeded(state: AppState) {
        guard !didStart else { return }
        didStart = true

        let capture = AudioCaptureService()
        let transcriber = TranscriptionService()
        self.transcriber = transcriber
        let pipeline = CapturePipeline(state: state, capture: capture, transcriber: transcriber)
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
            state.status = .error("Hotkey monitoring requires Accessibility permission. Grant it in System Settings → Privacy & Security → Accessibility, then restart voxline.")
        }

        prepareIfNeeded(state: state, transcriber: transcriber)
    }

    /// Ensure the speech-recognition model is downloaded AND loaded into the
    /// Apple Neural Engine before the user can record. The first launch after
    /// install does both; later launches just re-prewarm (fast — ANE bundle
    /// cache makes subsequent loads ~seconds, not minutes).
    private func prepareIfNeeded(state: AppState, transcriber: TranscriptionService) {
        let needsDownload = !TranscriptionService.isModelCached(transcriber.model)

        if needsDownload {
            state.status = .downloadingModel(progress: 0)
            let window = ModelDownloadWindow()
            downloadWindow = window
            window.show(state: state)
        } else {
            // Cached: prewarm silently in the background. No window — but the
            // chord is gated via state.status.blocksRecording, and the
            // menu-bar icon switches to gearshape.circle so the user has a
            // hint if they try to record before prewarm completes.
            state.status = .preparingModel
        }

        Task { @MainActor in
            do {
                if needsDownload {
                    try await transcriber.prepareModel { progress in
                        Task { @MainActor in
                            // Only push progress updates while still in the
                            // downloading state, to avoid clobbering a later
                            // .error set by a different code path.
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
