// voxline/Wizard/FirstRunWindowController.swift
import AppKit
import SwiftUI

@MainActor
final class FirstRunWindowController {

    private var window: NSWindow?

    func show(
        state: AppState,
        settings: AppSettings,
        model: WhisperModel,
        chord: HotkeyChord,
        onRetryDownload: @escaping () -> Void,
        onComplete: @escaping () -> Void
    ) {
        if let window {
            window.makeKeyAndOrderFront(nil); NSApp.activate(); return
        }
        let vm = WizardViewModel(settings: settings)
        vm.onComplete = { [weak self] in
            self?.close()
            onComplete()
        }
        let root = WizardRootView(vm: vm, state: state, model: model, chord: chord, onRetryDownload: onRetryDownload)
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
        win.identifier = WindowVisibilityCoordinator.dockworthyIdentifier

        self.window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func close() {
        window?.orderOut(nil)
        window = nil
    }
}
