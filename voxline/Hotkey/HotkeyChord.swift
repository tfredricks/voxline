// voxline/Hotkey/HotkeyChord.swift
import CoreGraphics
import Foundation
import IOKit.hidsystem

/// Codable value type for the hold-to-talk chord.
/// Pure data; flag-bit matching uses CGEventFlags via `Modifier.deviceMask`.
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
    }

    let modifierA: Modifier
    let modifierB: Modifier

    static let `default` = HotkeyChord(modifierA: .leftControl, modifierB: .leftOption)

    var displayName: String { "\(modifierA.displayName) + \(modifierB.displayName)" }

    /// Returns true when both modifier device-bits are present in `flags.rawValue`.
    /// Caller derives the two booleans from the live CGEventFlags before calling.
    func matches(modAFlag: Bool, modBFlag: Bool) -> Bool { modAFlag && modBFlag }
}
