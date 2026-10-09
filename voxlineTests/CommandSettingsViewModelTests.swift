import Foundation
import Testing
@testable import voxline

@Suite @MainActor struct CommandSettingsViewModelTests {

    @MainActor
    final class Counter {
        var count = 0
    }

    private let noTyping: KeyComboValidator.Translator = { _, _ in nil }

    private func suite() -> UserDefaults {
        UserDefaults(suiteName: "voxline-test-\(UUID().uuidString)")!
    }

    private func make(
        _ defaults: UserDefaults,
        chords: ChordSet = .default,
        counter: Counter? = nil,
        translate: KeyComboValidator.Translator? = nil,
        reserved: @escaping () -> [KeyCombo] = { [] }
    ) -> CommandSettingsViewModel {
        CommandSettingsViewModel(
            store: PresetStore(defaults: defaults),
            chords: { chords },
            onChange: { counter?.count += 1 },
            translate: translate ?? noTyping,
            reserved: reserved
        )
    }

    private let custom = PresetShortcut(
        id: UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!,
        combo: KeyCombo(keyCode: 0, modifiers: .command),
        name: "Shout",
        instruction: "Make it louder."
    )

    // MARK: - Loading

    @Test func loads_the_shipped_defaults() {
        let vm = make(suite())
        #expect(vm.presets == PresetShortcut.defaults)
    }

    @Test func loads_stored_presets() {
        let d = suite()
        PresetStore(defaults: d).save([custom])
        #expect(make(d).presets == [custom])
    }

    // MARK: - Combos

    @Test func preset_cannot_take_the_meeting_shortcut() {
        let meeting = KeyCombo(keyCode: 46, modifiers: [.control, .option])
        let vm = make(suite(), reserved: { [meeting] })
        let id = vm.presets[0].id
        #expect(vm.updateCombo(meeting, for: id) == .rejected(CommandSettingsViewModel.meetingShortcutTaken))
    }

    @Test func duplicate_combo_is_rejected_and_not_applied() {
        let d = suite()
        let counter = Counter()
        let vm = make(d, counter: counter)
        let first = PresetShortcut.defaults[0]
        let second = PresetShortcut.defaults[1]

        let verdict = vm.updateCombo(first.combo, for: second.id)

        #expect(verdict == .rejected("Another preset already uses this shortcut."))
        #expect(vm.presets[1].combo == second.combo)
        #expect(counter.count == 0)
        #expect(PresetStore(defaults: d).load() == PresetShortcut.defaults)
    }

    @Test func combo_covering_the_command_chord_is_rejected() {
        let vm = make(suite())
        let id = PresetShortcut.defaults[0].id
        let verdict = vm.updateCombo(KeyCombo(keyCode: 18, modifiers: [.shift, .option]), for: id)
        #expect(verdict == .rejected("⇧⌥ is your command hotkey"))
        #expect(vm.presets[0].combo == PresetShortcut.defaults[0].combo)
    }

    @Test func accepted_combo_is_applied_saved_and_reported() {
        let d = suite()
        let counter = Counter()
        let vm = make(d, counter: counter)
        let id = PresetShortcut.defaults[2].id
        let combo = KeyCombo(keyCode: 17, modifiers: [.command, .control])

        let verdict = vm.updateCombo(combo, for: id)

        #expect(verdict == .ok)
        #expect(vm.presets[2].combo == combo)
        #expect(PresetStore(defaults: d).load()[2].combo == combo)
        #expect(counter.count == 1)
    }

    @Test func combo_with_a_typed_character_is_applied_with_its_warning() {
        let d = suite()
        let counter = Counter()
        let vm = make(d, counter: counter, translate: { _, _ in "∑" })
        let id = PresetShortcut.defaults[0].id
        let combo = KeyCombo(keyCode: 13, modifiers: .option)

        let verdict = vm.updateCombo(combo, for: id)

        #expect(verdict == .warning("⌥W types “∑” on your keyboard. Voxline will capture it everywhere."))
        #expect(vm.presets[0].combo == combo)
        #expect(PresetStore(defaults: d).load()[0].combo == combo)
        #expect(counter.count == 1)
    }

    @Test func combo_for_an_unknown_row_changes_nothing() {
        let counter = Counter()
        let vm = make(suite(), counter: counter)
        _ = vm.updateCombo(KeyCombo(keyCode: 17, modifiers: .command), for: UUID())
        #expect(vm.presets == PresetShortcut.defaults)
        #expect(counter.count == 0)
    }

    // MARK: - Text fields

    @Test func name_and_instruction_edits_save_and_report_once_each() {
        let d = suite()
        let counter = Counter()
        let vm = make(d, counter: counter)
        let id = PresetShortcut.defaults[1].id

        vm.updateName("Shorter", for: id)
        vm.updateInstruction("Cut it in half.", for: id)

        #expect(vm.presets[1].name == "Shorter")
        #expect(vm.presets[1].instruction == "Cut it in half.")
        let stored = PresetStore(defaults: d).load()[1]
        #expect(stored.name == "Shorter")
        #expect(stored.instruction == "Cut it in half.")
        #expect(counter.count == 2)
    }

    @Test func committing_an_unchanged_value_is_not_a_mutation() {
        let counter = Counter()
        let vm = make(suite(), counter: counter)
        let first = PresetShortcut.defaults[0]
        vm.updateName(first.name, for: first.id)
        vm.updateInstruction(first.instruction, for: first.id)
        #expect(counter.count == 0)
    }

    // MARK: - Rows

    @Test func add_preset_appends_an_unrecorded_row_and_saves() throws {
        let d = suite()
        let counter = Counter()
        let vm = make(d, counter: counter)

        vm.addPreset()

        #expect(vm.presets.count == 4)
        let added = try #require(vm.presets.last)
        #expect(added.name == "New preset")
        #expect(added.instruction == "")
        #expect(added.combo == KeyCombo(keyCode: 0, modifiers: []))
        #expect(added.needsShortcut)
        #expect(!PresetShortcut.defaults.map(\.id).contains(added.id))
        #expect(PresetStore(defaults: d).load() == vm.presets)
        #expect(counter.count == 1)
    }

    @Test func added_row_can_record_a_shortcut() {
        let vm = make(suite())
        vm.addPreset()
        let id = vm.presets[3].id
        let combo = KeyCombo(keyCode: 21, modifiers: .option)
        #expect(vm.updateCombo(combo, for: id) == .ok)
        #expect(!vm.presets[3].needsShortcut)
    }

    @Test func two_unrecorded_rows_do_not_block_each_other() {
        let vm = make(suite())
        vm.addPreset()
        vm.addPreset()
        let combo = KeyCombo(keyCode: 21, modifiers: .option)
        #expect(vm.updateCombo(combo, for: vm.presets[3].id) == .ok)
        #expect(vm.updateCombo(KeyCombo(keyCode: 23, modifiers: .option), for: vm.presets[4].id) == .ok)
    }

    @Test func remove_persists() {
        let d = suite()
        let counter = Counter()
        let vm = make(d, counter: counter)
        let removed = PresetShortcut.defaults[1]

        vm.remove(removed.id)

        #expect(vm.presets == [PresetShortcut.defaults[0], PresetShortcut.defaults[2]])
        #expect(PresetStore(defaults: d).load() == vm.presets)
        #expect(counter.count == 1)
    }

    @Test func removing_every_row_keeps_an_empty_list() {
        let d = suite()
        let vm = make(d)
        for p in PresetShortcut.defaults { vm.remove(p.id) }
        #expect(vm.presets.isEmpty)
        #expect(PresetStore(defaults: d).load().isEmpty)
    }

    @Test func restore_defaults_rewrites_the_three_defaults() {
        let d = suite()
        PresetStore(defaults: d).save([custom])
        let counter = Counter()
        let vm = make(d, counter: counter)

        vm.restoreDefaults()

        #expect(vm.presets == PresetShortcut.defaults)
        #expect(PresetStore(defaults: d).load() == PresetShortcut.defaults)
        #expect(counter.count == 1)
    }

    // MARK: - Warnings

    @Test func shipped_defaults_warn_with_the_typed_character() {
        let vm = make(suite(), translate: { _, _ in "™" })
        #expect(vm.warning(for: PresetShortcut.defaults[1].id)
                == "⌥2 types “™” on your keyboard. Voxline will capture it everywhere.")
    }

    @Test func no_warning_when_the_combo_types_nothing() {
        let vm = make(suite())
        #expect(vm.warning(for: PresetShortcut.defaults[0].id) == nil)
    }

    @Test func warning_reports_a_combo_that_now_covers_a_chord() {
        let d = suite()
        PresetStore(defaults: d).save([PresetShortcut(
            id: custom.id,
            combo: KeyCombo(keyCode: 0, modifiers: [.shift, .control]),
            name: "Shout",
            instruction: "Make it louder."
        )])
        let vm = make(d)
        #expect(vm.warning(for: custom.id) == "⇧⌃ is your dictation hotkey")
    }

    @Test func warning_reports_a_duplicate_from_a_hand_edited_store() {
        let d = suite()
        let twin = PresetShortcut(id: UUID(), combo: custom.combo, name: "Twin", instruction: "Again.")
        PresetStore(defaults: d).save([custom, twin])
        let vm = make(d)
        #expect(vm.warning(for: twin.id) == "Another preset already uses this shortcut.")
    }

    @Test func unrecorded_row_with_an_instruction_has_no_warning() {
        let vm = make(suite(), translate: { _, _ in "a" })
        vm.addPreset()
        vm.updateInstruction("Do it.", for: vm.presets[3].id)
        #expect(vm.warning(for: vm.presets[3].id) == nil)
    }

    @Test func new_preset_warns_that_it_has_no_instruction() {
        let vm = make(suite())
        vm.addPreset()
        #expect(vm.warning(for: vm.presets[3].id) == "This preset has no instruction, so its shortcut does nothing.")
    }

    @Test func blank_instruction_warning_wins_over_the_combo_warning() {
        let d = suite()
        let row = PresetShortcut(id: UUID(), combo: KeyCombo(keyCode: 0, modifiers: [.control, .option]), name: "Empty", instruction: " \n ")
        PresetStore(defaults: d).save([row])
        let vm = make(d, translate: { _, _ in "å" })
        #expect(vm.warning(for: row.id) == "This preset has no instruction, so its shortcut does nothing.")
    }

    @Test func warning_follows_the_current_chords() {
        var chords = ChordSet.default
        let d = suite()
        let row = PresetShortcut(id: UUID(), combo: KeyCombo(keyCode: 0, modifiers: [.command, .option]), name: "R", instruction: "Do it.")
        PresetStore(defaults: d).save([row])
        let vm = CommandSettingsViewModel(
            store: PresetStore(defaults: d),
            chords: { chords },
            onChange: {},
            translate: noTyping
        )
        #expect(vm.warning(for: row.id) == nil)
        chords = ChordSet(dictation: .default, command: HotkeyChord(modifierA: .leftCommand, modifierB: .leftOption))
        #expect(vm.warning(for: row.id) == "⌘⌥ is your command hotkey")
    }
}
