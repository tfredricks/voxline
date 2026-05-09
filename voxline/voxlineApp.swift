import SwiftUI

@main
struct voxlineApp: App {

    @State private var appState = AppState()
    @State private var coordinator = AppCoordinator()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(state: appState)
        } label: {
            MenuBarLabel(state: appState, coordinator: coordinator)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environment(appState)
        }

        // PLAN 2 ONLY — Window scene removed in Plan 3 once paste replaces
        // the debug verification UI.
        Window("voxline — Transcripts (debug)", id: "debug-transcripts") {
            DebugTranscriptWindow(state: appState)
        }
        .defaultSize(width: 520, height: 360)
    }
}

/// Renders the menu-bar icon and triggers coordinator startup on first appear.
/// `.task` here fires when the menu-bar item is installed at app launch.
private struct MenuBarLabel: View {
    @Bindable var state: AppState
    let coordinator: AppCoordinator

    var body: some View {
        Image(systemName: MenuBarIcon.symbolName(for: state.status))
            .task {
                coordinator.startIfNeeded(state: state)
            }
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

        if !TranscriptionService.isModelCached(transcriber.model) {
            beginModelDownload(state: state, transcriber: transcriber)
        }
    }

    private func beginModelDownload(state: AppState, transcriber: TranscriptionService) {
        state.status = .downloadingModel(progress: 0)
        let window = ModelDownloadWindow()
        downloadWindow = window
        window.show(state: state)

        Task { @MainActor in
            do {
                try await transcriber.prepareModel { progress in
                    Task { @MainActor in
                        // Only push progress updates while we're still in the
                        // downloading state, to avoid clobbering a later .error
                        // or .idle set by a different code path.
                        if case .downloadingModel = state.status {
                            state.status = .downloadingModel(progress: progress)
                        }
                    }
                }
                if case .downloadingModel = state.status {
                    state.status = .idle
                }
                downloadWindow?.close()
                downloadWindow = nil
            } catch {
                state.status = .error("Model download failed: \(error.localizedDescription). Quit and relaunch voxline to retry.")
                downloadWindow?.close()
                downloadWindow = nil
            }
        }
    }
}
