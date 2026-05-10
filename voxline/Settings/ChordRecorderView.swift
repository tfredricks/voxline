// voxline/Settings/ChordRecorderView.swift
import AppKit
import Carbon.HIToolbox
import IOKit.hidsystem
import SwiftUI

struct ChordRecorderView: View {

    @Binding var chord: HotkeyChord

    @State private var isRecording = false
    @State private var flagsMonitor: Any?
    @State private var keyMonitor: Any?
    @State private var firstModifier: HotkeyChord.Modifier?
    @State private var unsupportedHint: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text(chord.displayName)
                    .monospaced()
                    .fixedSize()
                if isRecording {
                    Text(firstModifier == nil ? "Press first modifier… (Esc to cancel)" : "Now press second modifier… (Esc to cancel)")
                        .foregroundStyle(.secondary)
                    Button("Cancel") { stop() }
                } else {
                    Button("Record chord…") { start() }
                }
            }
            if let hint = unsupportedHint {
                Text(hint)
                    .foregroundStyle(.orange)
                    .font(.callout)
            }
            if let warning = chord.conflictWarning {
                Text(warning)
                    .foregroundStyle(.orange)
                    .font(.callout)
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        firstModifier = nil
        unsupportedHint = nil
        isRecording = true
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            handle(event)
            return event
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Esc cancels recording; consume the event so it doesn't propagate.
            if event.keyCode == UInt16(kVK_Escape) {
                stop()
                return nil
            }
            return event
        }
    }

    private func stop() {
        if let m = flagsMonitor { NSEvent.removeMonitor(m) }
        if let m = keyMonitor   { NSEvent.removeMonitor(m) }
        flagsMonitor = nil
        keyMonitor = nil
        firstModifier = nil
        unsupportedHint = nil
        isRecording = false
    }

    private func handle(_ event: NSEvent) {
        guard event.type == .flagsChanged else { return }

        if let pressed = modifier(from: event) {
            let bit = pressed.deviceMaskBit
            let raw = UInt64(event.cgEvent?.flags.rawValue ?? 0)
            let isDown = (raw & bit) != 0
            guard isDown else { return }

            unsupportedHint = nil
            if let first = firstModifier {
                guard pressed != first else { return }
                chord = HotkeyChord(modifierA: first, modifierB: pressed)
                stop()
            } else {
                firstModifier = pressed
            }
            return
        }

        // The user pressed a key voxline doesn't support as a modifier. Name
        // the common offenders (Fn / Caps Lock) so the user understands why
        // nothing happened, instead of silently swallowing the event.
        if let name = unsupportedKeyName(for: Int(event.keyCode)) {
            unsupportedHint = "\(name) isn't supported — use Control, Option, Command, or Shift."
        }
    }

    private func modifier(from event: NSEvent) -> HotkeyChord.Modifier? {
        switch Int(event.keyCode) {
        case kVK_Control:      return .leftControl
        case kVK_RightControl: return .rightControl
        case kVK_Option:       return .leftOption
        case kVK_RightOption:  return .rightOption
        case kVK_Command:      return .leftCommand
        case kVK_RightCommand: return .rightCommand
        case kVK_Shift:        return .leftShift
        case kVK_RightShift:   return .rightShift
        default: return nil
        }
    }

    private func unsupportedKeyName(for keyCode: Int) -> String? {
        switch keyCode {
        case kVK_Function: return "Fn / Globe"
        case kVK_CapsLock: return "Caps Lock"
        default:           return nil
        }
    }
}
