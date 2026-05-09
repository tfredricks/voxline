// voxline/Settings/ChordRecorderView.swift
import AppKit
import Carbon.HIToolbox
import IOKit.hidsystem
import SwiftUI

struct ChordRecorderView: View {

    @Binding var chord: HotkeyChord

    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var firstModifier: HotkeyChord.Modifier?

    var body: some View {
        HStack(spacing: 12) {
            Text(chord.displayName)
                .monospaced()
                .frame(minWidth: 200, alignment: .leading)
            if isRecording {
                Text(firstModifier == nil ? "Press first modifier…" : "Now press second modifier…")
                    .foregroundStyle(.secondary)
                Button("Cancel") { stop() }
            } else {
                Button("Record chord…") { start() }
            }
        }
    }

    private func start() {
        firstModifier = nil
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            handle(event)
            return event
        }
    }

    private func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        firstModifier = nil
        isRecording = false
    }

    private func handle(_ event: NSEvent) {
        guard let pressed = modifier(from: event), event.type == .flagsChanged else { return }
        // Edge: only react on key-DOWN (modifier mask non-zero for that bit)
        let bit = pressed.deviceMaskBit
        let raw = UInt64(event.cgEvent?.flags.rawValue ?? 0)
        let isDown = (raw & bit) != 0
        guard isDown else { return }

        if let first = firstModifier {
            guard pressed != first else { return }
            chord = HotkeyChord(modifierA: first, modifierB: pressed)
            stop()
        } else {
            firstModifier = pressed
        }
    }

    private func modifier(from event: NSEvent) -> HotkeyChord.Modifier? {
        // event.keyCode for flagsChanged identifies which physical modifier key.
        // Carbon kVK_* constants:
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
}
