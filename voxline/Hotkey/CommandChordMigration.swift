// voxline/Hotkey/CommandChordMigration.swift
import Foundation

enum CommandChordMigration {
    /// `stored` is the raw `voxline.hotkey.commandModifier` value, or nil.
    static func commandChord(dictation: HotkeyChord, stored: String?) -> HotkeyChord? {
        let raw = stored ?? HotkeyChord.Modifier.leftOption.rawValue
        if raw == "off" { return defaultOrOff(dictation) }
        guard let modifier = HotkeyChord.Modifier(rawValue: raw) else {
            return commandChord(dictation: dictation, stored: HotkeyChord.Modifier.leftOption.rawValue)
        }
        if dictation.keys.contains(modifier) { return defaultOrOff(dictation) }
        return HotkeyChord(modifierA: dictation.modifierA, modifierB: modifier)
    }

    private static func defaultOrOff(_ dictation: HotkeyChord) -> HotkeyChord? {
        HotkeyChord.defaultCommand.keys == dictation.keys ? nil : .defaultCommand
    }
}
