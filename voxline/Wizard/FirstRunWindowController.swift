// voxline/Wizard/FirstRunWindowController.swift
import AppKit
import SwiftUI

@MainActor
final class FirstRunWindowController {

    private var window: NSWindow?

    /// Checks `engine`'s readiness first, so the window appears once that
    /// check returns; a ready engine skips the speech-engine step.
    func show(
        state: AppState,
        settings: AppSettings,
        engine: any TranscriptionEngine,
        chord: HotkeyChord,
        onRetryDownload: @escaping () -> Void,
        onComplete: @escaping () -> Void
    ) async {
        if let window {
            window.presentInAccessoryApp()
            return
        }
        let skipEngineStep = await engine.readiness() == .ready
        if let window {
            window.presentInAccessoryApp()
            return
        }
        let vm = WizardViewModel(settings: settings, skipEngineStep: skipEngineStep)
        vm.onComplete = { [weak self] in
            self?.close()
            onComplete()
        }
        let root = WizardRootView(
            vm: vm,
            state: state,
            engineName: engine.id.shortName,
            chord: chord,
            onRetryDownload: onRetryDownload
        )
        let host = NSHostingView(rootView: root)

        // Hide close + minimize so the user can't dismiss without completing.
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 540),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        win.title = "Welcome to Voxline"
        win.contentView = host
        win.center()
        win.isReleasedWhenClosed = false
        self.window = win
        win.presentInAccessoryApp()
    }

    func bringForward() {
        window?.presentInAccessoryApp()
    }

    func close() {
        window?.close()
        window = nil
    }
}
