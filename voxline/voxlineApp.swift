import SwiftUI

@main
struct voxlineApp: App {

    @State private var appState = AppState()
    @State private var coordinator = AppCoordinator()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(state: appState)
        } label: {
            Image(systemName: MenuBarIcon.symbolName(for: appState.status))
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
                .onAppear {
                    coordinator.startIfNeeded(state: appState)
                }
        }
        .defaultSize(width: 520, height: 360)
    }
}

/// Owns the long-lived runtime objects (HotkeyMonitor, AudioCapture,
/// TranscriptionService, CapturePipeline, RecordingPillWindow) and starts
/// them on first window appearance.
@MainActor
final class AppCoordinator {
    private var hotkeyMonitor: HotkeyMonitor?
    private var pillWindow: RecordingPillWindow?
    private var pipeline: CapturePipeline?
    private var didStart = false
    private var levelObservation: AnyObject?

    func startIfNeeded(state: AppState) {
        guard !didStart else { return }
        didStart = true

        let capture = AudioCaptureService()
        let transcriber = TranscriptionService()
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
                if let state { self?.pillWindow?.updateVisibility(state: state) }
            }
        }
        do {
            try monitor.start()
            hotkeyMonitor = monitor
        } catch {
            state.status = .error("Hotkey monitoring requires Accessibility permission. Grant it in System Settings → Privacy & Security → Accessibility, then restart voxline.")
        }
    }
}
