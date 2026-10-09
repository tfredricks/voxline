// voxline/Hotkey/ChordSet.swift
import Foundation

enum CaptureKind: Equatable, Hashable, Sendable {
    case dictation
    case command
}

/// The hotkey machine's configuration. `command == nil` means command mode is off.
struct ChordSet: Equatable, Sendable {
    var dictation: HotkeyChord
    var command: HotkeyChord?

    static let `default` = ChordSet(dictation: .default, command: .defaultCommand)

    var entries: [(kind: CaptureKind, chord: HotkeyChord)] {
        var e = [(CaptureKind.dictation, dictation)]
        if let command { e.append((.command, command)) }
        return e
    }

    func chord(for kind: CaptureKind) -> HotkeyChord? {
        kind == .dictation ? dictation : command
    }

    /// The kind whose chord equals `held` exactly. Dictation wins a tie,
    /// which can only happen when both chords are the same (the validator
    /// forbids it).
    func kind(matching held: Set<HotkeyChord.Modifier>) -> CaptureKind? {
        entries.first { $0.chord.keys == held }?.kind
    }

    /// Non-empty and strictly inside at least one chord.
    func isStrictSubsetOfAny(_ held: Set<HotkeyChord.Modifier>) -> Bool {
        !held.isEmpty && entries.contains { held.isStrictSubset(of: $0.chord.keys) }
    }

    var allKeys: Set<HotkeyChord.Modifier> { entries.reduce(into: []) { $0.formUnion($1.chord.keys) } }
    var families: ModifierFamilies { ModifierFamilies(modifiers: allKeys) }
}
