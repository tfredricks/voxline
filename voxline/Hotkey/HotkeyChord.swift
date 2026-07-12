// voxline/Hotkey/HotkeyChord.swift
import CoreGraphics
import Foundation
import IOKit.hidsystem

/// Codable value type for the hold-to-talk chord.
/// Pure data; flag-bit matching uses CGEventFlags via `Modifier.deviceMaskBit`.
struct HotkeyChord: Codable, Equatable {

    enum Modifier: String, Codable, CaseIterable {
        case leftControl
        case leftOption
        case leftCommand
        case leftShift
        case rightControl
        case rightOption
        case rightCommand
        case rightShift

        /// CGEventFlags raw bit that distinguishes left vs right per-device modifiers.
        /// Sourced from <IOKit/hidsystem/IOLLEvent.h> NX_DEVICE*KEYMASK constants.
        var deviceMaskBit: UInt64 {
            switch self {
            case .leftControl:  return UInt64(NX_DEVICELCTLKEYMASK)
            case .leftOption:   return UInt64(NX_DEVICELALTKEYMASK)
            case .leftCommand:  return UInt64(NX_DEVICELCMDKEYMASK)
            case .leftShift:    return UInt64(NX_DEVICELSHIFTKEYMASK)
            case .rightControl: return UInt64(NX_DEVICERCTLKEYMASK)
            case .rightOption:  return UInt64(NX_DEVICERALTKEYMASK)
            case .rightCommand: return UInt64(NX_DEVICERCMDKEYMASK)
            case .rightShift:   return UInt64(NX_DEVICERSHIFTKEYMASK)
            }
        }

        var displayName: String {
            switch self {
            case .leftControl:  return "Left Ctrl"
            case .leftOption:   return "Left Option"
            case .leftCommand:  return "Left Cmd"
            case .leftShift:    return "Left Shift"
            case .rightControl: return "Right Ctrl"
            case .rightOption:  return "Right Option"
            case .rightCommand: return "Right Cmd"
            case .rightShift:   return "Right Shift"
            }
        }

        /// True when this modifier's device-mask bit is set in `flags`.
        /// Bit-equivalent to the chord matching in `HotkeyMonitor`'s tap callback.
        func isHeld(in flags: CGEventFlags) -> Bool {
            flags.contains(CGEventFlags(rawValue: deviceMaskBit))
        }
    }

    let modifierA: Modifier
    let modifierB: Modifier

    static let `default` = HotkeyChord(modifierA: .leftShift, modifierB: .leftControl)

    var displayName: String { "\(modifierA.displayName) + \(modifierB.displayName)" }

    /// Soft warning for chord combinations known to conflict with system
    /// accessibility features. Returns nil when no conflict is known.
    var conflictWarning: String? {
        let a = modifierA, b = modifierB
        let isControl: (Modifier) -> Bool = { $0 == .leftControl || $0 == .rightControl }
        let isOption:  (Modifier) -> Bool = { $0 == .leftOption  || $0 == .rightOption }
        let isCtrlOpt = (isControl(a) && isOption(b)) || (isOption(a) && isControl(b))
        if isCtrlOpt {
            return "This hotkey matches the VoiceOver modifier (Ctrl+Option). If VoiceOver is on, hold-to-talk may conflict."
        }
        return nil
    }

    /// Soft warning for a chosen command modifier. Returns nil when command
    /// mode is off (`command == nil`) or the choice is clean. Two known problems:
    ///   1. The command modifier equals one of the two chord keys — command mode
    ///      would then be "always on" (dictation impossible). Rejected upstream
    ///      in `HotkeyMonitor`, but warn here so the user understands.
    ///   2. Holding the command modifier together with the chord forms Ctrl+Option,
    ///      the VoiceOver modifier.
    static func commandModifierConflictWarning(command: Modifier?, chord: HotkeyChord) -> String? {
        guard let command else { return nil }
        if command == chord.modifierA || command == chord.modifierB {
            return "The command modifier can't be one of your two hotkey keys. Pick a different key or set it to Off."
        }
        let all = [chord.modifierA, chord.modifierB, command]
        let isControl: (Modifier) -> Bool = { $0 == .leftControl || $0 == .rightControl }
        let isOption:  (Modifier) -> Bool = { $0 == .leftOption  || $0 == .rightOption }
        if all.contains(where: isControl) && all.contains(where: isOption) {
            return "Holding this together with your hotkey forms Ctrl+Option, the VoiceOver modifier. If VoiceOver is on, command mode may conflict."
        }
        return nil
    }

}
