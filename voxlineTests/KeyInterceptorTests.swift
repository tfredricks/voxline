import CoreGraphics
import Foundation
import Testing
@testable import voxline

@Suite struct KeyInterceptorTests {

    private let esc = KeyCombo.escapeKeyCode
    private let optionOne = KeyCombo(keyCode: 18, modifiers: .option)
    private let presetID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!

    private var presetConfig: KeyInterceptor.Config {
        KeyInterceptor.Config(presetsArmed: true, presets: [optionOne: presetID])
    }

    private func decide(
        down: Bool = true,
        _ keyCode: UInt16,
        flags: CGEventFlags = [],
        autorepeat: Bool = false,
        synthetic: Bool = false,
        config: KeyInterceptor.Config,
        downs: Set<UInt16> = []
    ) -> (decision: KeyInterceptor.Decision, swallowedDowns: Set<UInt16>) {
        KeyInterceptor.decide(
            isKeyDown: down,
            keyCode: keyCode,
            flags: flags,
            isAutorepeat: autorepeat,
            isSynthetic: synthetic,
            config: config,
            swallowedDowns: downs
        )
    }

    // MARK: - Esc

    @Test func armed_esc_with_no_modifiers_is_swallowed_and_fires() {
        let d = decide(esc, config: .init(escapeArmed: true))
        #expect(d.decision == .swallowAndFire(.escape))
        #expect(d.swallowedDowns == [53])
    }

    @Test func disarmed_esc_passes() {
        let d = decide(esc, config: .init(escapeArmed: false))
        #expect(d.decision == .pass)
        #expect(d.swallowedDowns.isEmpty)
    }

    @Test(arguments: [CGEventFlags.maskCommand, .maskAlternate, .maskControl, .maskShift, [.maskCommand, .maskShift]])
    func armed_esc_with_a_modifier_passes(flags: CGEventFlags) {
        let d = decide(esc, flags: flags, config: .init(escapeArmed: true))
        #expect(d.decision == .pass)
        #expect(d.swallowedDowns.isEmpty)
    }

    @Test(arguments: [CGEventFlags.maskAlphaShift, .maskSecondaryFn, .maskNumericPad, .maskNonCoalesced])
    func armed_esc_with_a_non_family_flag_still_fires(flags: CGEventFlags) {
        let d = decide(esc, flags: flags, config: .init(escapeArmed: true))
        #expect(d.decision == .swallowAndFire(.escape))
    }

    @Test func esc_holding_only_the_chord_modifiers_fires() {
        let config = KeyInterceptor.Config(escapeArmed: true, chordFamilies: ChordSet.default.families)
        let held: CGEventFlags = [.maskShift, .maskControl, CGEventFlags(rawValue: HotkeyChord.Modifier.leftShift.deviceMaskBit)]
        let d = decide(esc, flags: held, config: config)
        #expect(d.decision == .swallowAndFire(.escape))
        #expect(d.swallowedDowns == [53])
    }

    @Test func esc_holding_the_command_chord_fires_because_both_chords_count() {
        let config = KeyInterceptor.Config(escapeArmed: true, chordFamilies: ChordSet.default.families)
        let d = decide(esc, flags: [.maskShift, .maskAlternate], config: config)
        #expect(d.decision == .swallowAndFire(.escape))
    }

    @Test func esc_with_a_modifier_beyond_the_chords_passes() {
        let config = KeyInterceptor.Config(escapeArmed: true, chordFamilies: ChordSet.default.families)
        let d = decide(esc, flags: [.maskShift, .maskControl, .maskCommand], config: config)
        #expect(d.decision == .pass)
        #expect(d.swallowedDowns.isEmpty)
    }

    @Test func chord_families_do_not_arm_a_disarmed_esc() {
        let config = KeyInterceptor.Config(escapeArmed: false, chordFamilies: ChordSet.default.families)
        #expect(decide(esc, flags: [.maskShift, .maskControl], config: config).decision == .pass)
    }

    @Test func autorepeat_of_a_swallowed_esc_is_swallowed_without_firing_again() {
        let d = decide(esc, autorepeat: true, config: .init(escapeArmed: false), downs: [53])
        #expect(d.decision == .swallow)
        #expect(d.swallowedDowns == [53])
    }

    @Test func synthetic_esc_passes_and_leaves_downs_unchanged() {
        let d = decide(esc, synthetic: true, config: .init(escapeArmed: true), downs: [18])
        #expect(d.decision == .pass)
        #expect(d.swallowedDowns == [18])
    }

    // MARK: - keyUp pairing

    @Test func keyUp_after_a_swallowed_down_is_swallowed_and_clears_it() {
        let d = decide(down: false, esc, config: .init(), downs: [53])
        #expect(d.decision == .swallow)
        #expect(d.swallowedDowns.isEmpty)
    }

    @Test func keyUp_with_no_swallowed_down_passes() {
        let d = decide(down: false, esc, config: .init(escapeArmed: true))
        #expect(d.decision == .pass)
        #expect(d.swallowedDowns.isEmpty)
    }

    @Test func keyUp_of_another_key_keeps_the_pending_entry() {
        let d = decide(down: false, 0, config: .init(), downs: [53])
        #expect(d.decision == .pass)
        #expect(d.swallowedDowns == [53])
    }

    @Test func synthetic_keyUp_of_a_swallowed_key_passes_and_keeps_the_entry() {
        let d = decide(down: false, 18, synthetic: true, config: presetConfig, downs: [18])
        #expect(d.decision == .pass)
        #expect(d.swallowedDowns == [18])
    }

    @Test func a_passed_keyDown_clears_a_stale_entry_so_its_keyUp_passes() {
        let down = decide(18, config: .init(), downs: [18])
        #expect(down.decision == .pass)
        #expect(down.swallowedDowns.isEmpty)
        let up = decide(down: false, 18, config: .init(), downs: down.swallowedDowns)
        #expect(up.decision == .pass)
    }

    // MARK: - Presets

    @Test func matching_preset_while_armed_is_swallowed_and_fires() {
        let d = decide(18, flags: .maskAlternate, config: presetConfig)
        #expect(d.decision == .swallowAndFire(.preset(presetID)))
        #expect(d.swallowedDowns == [18])
    }

    @Test func preset_with_an_extra_modifier_passes() {
        let d = decide(18, flags: [.maskAlternate, .maskShift], config: presetConfig)
        #expect(d.decision == .pass)
        #expect(d.swallowedDowns.isEmpty)
    }

    @Test func preset_key_without_its_modifier_passes() {
        #expect(decide(18, config: presetConfig).decision == .pass)
    }

    @Test func preset_with_caps_lock_fn_and_keypad_flags_still_fires() {
        let flags: CGEventFlags = [.maskAlternate, .maskAlphaShift, .maskSecondaryFn, .maskNumericPad]
        #expect(decide(18, flags: flags, config: presetConfig).decision == .swallowAndFire(.preset(presetID)))
    }

    @Test func preset_with_device_side_bits_still_fires() {
        let flags = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | HotkeyChord.Modifier.rightOption.deviceMaskBit)
        #expect(decide(18, flags: flags, config: presetConfig).decision == .swallowAndFire(.preset(presetID)))
    }

    @Test func preset_autorepeat_is_swallowed_without_firing() {
        let d = decide(18, flags: .maskAlternate, autorepeat: true, config: presetConfig)
        #expect(d.decision == .swallow)
        #expect(d.swallowedDowns == [18])
    }

    @Test func autorepeat_after_the_modifier_is_released_stays_swallowed() {
        let d = decide(18, autorepeat: true, config: presetConfig, downs: [18])
        #expect(d.decision == .swallow)
        #expect(d.swallowedDowns == [18])
    }

    @Test func disarmed_presets_pass() {
        var config = presetConfig
        config.presetsArmed = false
        let d = decide(18, flags: .maskAlternate, config: config)
        #expect(d.decision == .pass)
        #expect(d.swallowedDowns.isEmpty)
    }

    @Test func synthetic_preset_combo_passes() {
        let d = decide(18, flags: .maskAlternate, synthetic: true, config: presetConfig)
        #expect(d.decision == .pass)
        #expect(d.swallowedDowns.isEmpty)
    }

    @Test func swallowed_preset_keyUp_is_swallowed_even_after_the_modifier_is_up() {
        let down = decide(18, flags: .maskAlternate, config: presetConfig)
        let up = decide(down: false, 18, config: presetConfig, downs: down.swallowedDowns)
        #expect(up.decision == .swallow)
        #expect(up.swallowedDowns.isEmpty)
    }

    @Test func swallowed_preset_keyUp_is_swallowed_after_disarming() {
        var config = presetConfig
        config.presetsArmed = false
        let up = decide(down: false, 18, flags: .maskAlternate, config: config, downs: [18])
        #expect(up.decision == .swallow)
    }

    @Test func esc_wins_over_a_preset_map_entry_for_esc() {
        let config = KeyInterceptor.Config(
            escapeArmed: true,
            presetsArmed: true,
            presets: [KeyCombo(keyCode: esc, modifiers: []): presetID]
        )
        #expect(decide(esc, config: config).decision == .swallowAndFire(.escape))
    }

    @Test func unrelated_keys_pass() {
        let config = KeyInterceptor.Config(escapeArmed: true, presetsArmed: true, presets: [optionOne: presetID])
        #expect(decide(0, config: config).decision == .pass)
        #expect(decide(19, flags: .maskAlternate, config: config).decision == .pass)
    }

    // MARK: - Preset map

    private func preset(_ combo: KeyCombo, id: UUID = UUID(), instruction: String = "Do it.") -> PresetShortcut {
        PresetShortcut(id: id, combo: combo, name: "P", instruction: instruction)
    }

    @Test func preset_map_holds_each_combo_and_id() {
        let map = KeyInterceptor.presetMap(PresetShortcut.defaults)
        #expect(map.count == 3)
        for p in PresetShortcut.defaults {
            #expect(map[p.combo] == p.id)
        }
    }

    @Test func preset_map_keeps_the_first_of_duplicate_combos() {
        let first = UUID()
        let second = UUID()
        let map = KeyInterceptor.presetMap([preset(optionOne, id: first), preset(optionOne, id: second)])
        #expect(map == [optionOne: first])
    }

    @Test func preset_map_skips_rows_without_a_usable_shortcut() {
        let map = KeyInterceptor.presetMap([
            preset(KeyCombo(keyCode: 0, modifiers: [])),
            preset(KeyCombo(keyCode: 0, modifiers: .shift)),
            preset(KeyCombo(keyCode: esc, modifiers: .option)),
        ])
        #expect(map.isEmpty)
    }

    @Test func preset_map_skips_rows_with_a_blank_instruction() {
        let map = KeyInterceptor.presetMap([preset(optionOne, instruction: "  \n")])
        #expect(map.isEmpty)
    }

    @Test func unrecorded_row_never_swallows_its_placeholder_key() {
        let placeholder = PresetShortcut(id: UUID(), combo: KeyCombo(keyCode: 0, modifiers: []), name: "New preset", instruction: "Shout.")
        #expect(placeholder.needsShortcut)
        let config = KeyInterceptor.Config(presetsArmed: true, presets: KeyInterceptor.presetMap([placeholder]))
        #expect(decide(0, config: config).decision == .pass)
    }

    // MARK: - Arming

    @Test func presets_arm_only_when_installed_not_capturing_and_not_frontmost() {
        #expect(KeyInterceptor.presetsArmed(installed: true, capturingShortcut: false, voxlineIsFrontmost: false))
        #expect(!KeyInterceptor.presetsArmed(installed: false, capturingShortcut: false, voxlineIsFrontmost: false))
        #expect(!KeyInterceptor.presetsArmed(installed: true, capturingShortcut: true, voxlineIsFrontmost: false))
        #expect(!KeyInterceptor.presetsArmed(installed: true, capturingShortcut: false, voxlineIsFrontmost: true))
    }

    // MARK: - Install backoff

    @Test func install_is_attempted_when_nothing_has_failed() {
        #expect(KeyInterceptor.shouldAttemptInstall(lastFailure: nil, now: .now))
    }

    @Test func install_waits_ten_seconds_after_a_failure() {
        let failed = ContinuousClock.now
        #expect(!KeyInterceptor.shouldAttemptInstall(lastFailure: failed, now: failed))
        #expect(!KeyInterceptor.shouldAttemptInstall(lastFailure: failed, now: failed + .seconds(9.9)))
        #expect(KeyInterceptor.shouldAttemptInstall(lastFailure: failed, now: failed + .seconds(10)))
    }

    // MARK: - Instance state (no tap is installed)

    @Test func starts_unarmed_and_uninstalled() {
        let interceptor = KeyInterceptor(onEscape: {}, onPreset: { _ in })
        #expect(interceptor.config == KeyInterceptor.Config())
        #expect(!interceptor.isInstalled)
        interceptor.config.escapeArmed = true
        #expect(interceptor.config.escapeArmed)
        interceptor.uninstall()
        #expect(!interceptor.isInstalled)
    }
}
