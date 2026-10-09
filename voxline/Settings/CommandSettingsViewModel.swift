import Foundation
import Observation

/// Settings → Commands' preset rows. Every mutation saves to `PresetStore`
/// and then calls `onChange`, so the key interceptor picks up the new
/// shortcuts at once. A commit that changes nothing is not a mutation.
@Observable
@MainActor
final class CommandSettingsViewModel {

    static let meetingShortcutTaken = "This shortcut starts and stops meeting recording."

    private(set) var presets: [PresetShortcut]

    private let store: PresetStore
    private let chords: () -> ChordSet
    private let onChange: () -> Void
    private let translate: KeyComboValidator.Translator
    private let reserved: () -> [KeyCombo]

    init(
        store: PresetStore = PresetStore(),
        chords: @escaping () -> ChordSet,
        onChange: @escaping () -> Void,
        translate: @escaping KeyComboValidator.Translator = KeyComboValidator.liveTranslator,
        reserved: @escaping () -> [KeyCombo] = { [] }
    ) {
        self.store = store
        self.chords = chords
        self.onChange = onChange
        self.translate = translate
        self.reserved = reserved
        self.presets = store.load()
    }

    func updateName(_ name: String, for id: PresetShortcut.ID) {
        mutate(id) { $0.name = name }
    }

    func updateInstruction(_ instruction: String, for id: PresetShortcut.ID) {
        mutate(id) { $0.instruction = instruction }
    }

    /// A rejected combo is not applied. An accepted one, with or without a
    /// typed-character warning, is applied and saved.
    @discardableResult
    func updateCombo(_ combo: KeyCombo, for id: PresetShortcut.ID) -> KeyComboValidator.Verdict {
        guard presets.contains(where: { $0.id == id }) else { return .ok }
        let verdict = validate(combo, for: id)
        if case .rejected = verdict { return verdict }
        mutate(id) { $0.combo = combo }
        return verdict
    }

    func addPreset() {
        presets.append(PresetShortcut(
            id: UUID(),
            combo: KeyCombo(keyCode: 0, modifiers: []),
            name: "New preset",
            instruction: ""
        ))
        commit()
    }

    func remove(_ id: PresetShortcut.ID) {
        guard let index = presets.firstIndex(where: { $0.id == id }) else { return }
        presets.remove(at: index)
        commit()
    }

    func restoreDefaults() {
        presets = PresetShortcut.defaults
        commit()
    }

    /// A blank instruction first: the key interceptor leaves such a row out,
    /// so its combo captures nothing. Otherwise the row's combo
    /// validated against the other rows and the current chords: the
    /// typed-character warning, or a conflict that appeared after it was
    /// recorded. Nil for a clean combo or one not yet recorded, which the
    /// recorder already shows as "None".
    func warning(for id: PresetShortcut.ID) -> String? {
        guard let preset = presets.first(where: { $0.id == id }) else { return nil }
        if preset.instruction.isBlank { return "This preset has no instruction, so its shortcut does nothing." }
        guard !preset.needsShortcut else { return nil }
        switch validate(preset.combo, for: id) {
        case .ok: return nil
        case .warning(let message), .rejected(let message): return message
        }
    }

    private func validate(_ combo: KeyCombo, for id: PresetShortcut.ID) -> KeyComboValidator.Verdict {
        if reserved().contains(combo) { return .rejected(Self.meetingShortcutTaken) }
        let others = presets.filter { $0.id != id && !$0.needsShortcut }.map(\.combo)
        return KeyComboValidator.validate(combo, others: others, chords: chords(), translate: translate)
    }

    private func mutate(_ id: PresetShortcut.ID, _ change: (inout PresetShortcut) -> Void) {
        guard let index = presets.firstIndex(where: { $0.id == id }) else { return }
        var preset = presets[index]
        change(&preset)
        guard preset != presets[index] else { return }
        presets[index] = preset
        commit()
    }

    private func commit() {
        store.save(presets)
        onChange()
    }
}
