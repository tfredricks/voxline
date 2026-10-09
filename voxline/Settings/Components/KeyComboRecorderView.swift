import AppKit
import SwiftUI

/// Records a preset shortcut. While recording, hotkey input and presets are
/// suspended through `AppState.beginShortcutCapture(recorder:)`. Recording
/// stops on Cancel, Esc, an accepted combo, disappearing, the window
/// resigning key, the app deactivating, or another recorder starting. A combo
/// `onRecord` rejects shows its message and keeps recording.
struct KeyComboRecorderView: View {

    @Environment(AppState.self) private var appState

    /// Nil until a shortcut is recorded.
    let combo: KeyCombo?
    let onRecord: @MainActor (KeyCombo) -> KeyComboValidator.Verdict

    @State private var recorderID = UUID()
    @State private var isRecording = false
    @State private var keyMonitor: Any?
    @State private var rejection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(isRecording ? "Press a shortcut…" : (combo?.displayName ?? "None"))
                    .monospaced()
                    .foregroundStyle(combo != nil && !isRecording ? .primary : .secondary)
                    .fixedSize()
                if isRecording {
                    Button("Cancel") { stop() }
                } else {
                    Button("Record…") { start() }
                }
            }
            if let rejection {
                Text(rejection)
                    .foregroundStyle(.orange)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onDisappear { stop() }
        .onChange(of: appState.activeShortcutRecorder) { _, active in
            if active != recorderID { stop() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in stop() }
    }

    private var ownsCapture: Bool { appState.activeShortcutRecorder == recorderID }

    private func start() {
        guard !isRecording else { return }
        rejection = nil
        isRecording = true
        appState.beginShortcutCapture(recorder: recorderID)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard ownsCapture else { return event }
            handle(event)
            return nil
        }
    }

    private func stop() {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
        rejection = nil
        guard isRecording else { return }
        isRecording = false
        appState.endShortcutCapture(recorder: recorderID)
    }

    private func handle(_ event: NSEvent) {
        if event.keyCode == KeyCombo.escapeKeyCode {
            stop()
            return
        }
        guard !event.isARepeat else { return }
        let flags = event.cgEvent?.flags ?? CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))
        let candidate = KeyCombo(keyCode: event.keyCode, modifiers: ModifierFamilies(flags: flags))
        switch onRecord(candidate) {
        case .rejected(let message):
            rejection = message
        case .ok, .warning:
            stop()
        }
    }
}
