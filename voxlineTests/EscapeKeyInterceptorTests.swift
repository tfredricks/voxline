import Testing
import CoreGraphics
@testable import voxline

@Suite struct EscapeKeyInterceptorTests {

    private let esc: Int64 = 53

    private func decide(
        _ type: CGEventType,
        keyCode: Int64 = 53,
        flags: CGEventFlags = [],
        armed: Bool = true,
        swallowingKeyUp: Bool = false
    ) -> (swallow: Bool, escapeFired: Bool, swallowingKeyUp: Bool) {
        EscapeKeyInterceptor.shouldSwallow(type: type, keyCode: keyCode, flags: flags, armed: armed, swallowingKeyUp: swallowingKeyUp)
    }

    @Test func armed_esc_keyDown_is_swallowed_and_fires() {
        let d = decide(.keyDown)
        #expect(d.swallow)
        #expect(d.escapeFired)
        #expect(d.swallowingKeyUp)
    }

    @Test func disarmed_esc_passes() {
        let d = decide(.keyDown, armed: false)
        #expect(!d.swallow)
        #expect(!d.escapeFired)
        #expect(!d.swallowingKeyUp)
    }

    @Test(arguments: [CGEventFlags.maskCommand, .maskAlternate, .maskControl, .maskShift, [.maskCommand, .maskShift]])
    func esc_with_a_modifier_passes(flags: CGEventFlags) {
        let d = decide(.keyDown, flags: flags)
        #expect(!d.swallow)
        #expect(!d.escapeFired)
        #expect(!d.swallowingKeyUp)
    }

    @Test(arguments: [CGEventFlags.maskAlphaShift, .maskSecondaryFn, .maskNonCoalesced])
    func esc_with_a_non_blocking_flag_still_fires(flags: CGEventFlags) {
        let d = decide(.keyDown, flags: flags)
        #expect(d.swallow)
        #expect(d.escapeFired)
    }

    @Test func keyUp_after_a_swallowed_down_is_swallowed_and_resets() {
        let d = decide(.keyUp, swallowingKeyUp: true)
        #expect(d.swallow)
        #expect(!d.escapeFired)
        #expect(!d.swallowingKeyUp)
    }

    @Test func keyUp_after_disarming_is_still_swallowed() {
        let d = decide(.keyUp, armed: false, swallowingKeyUp: true)
        #expect(d.swallow)
        #expect(!d.swallowingKeyUp)
    }

    @Test func keyUp_with_no_swallowed_down_passes() {
        let d = decide(.keyUp)
        #expect(!d.swallow)
        #expect(!d.escapeFired)
        #expect(!d.swallowingKeyUp)
    }

    @Test func autorepeat_of_a_swallowed_esc_is_swallowed_without_firing() {
        let d = decide(.keyDown, armed: false, swallowingKeyUp: true)
        #expect(d.swallow)
        #expect(!d.escapeFired)
        #expect(d.swallowingKeyUp)
    }

    @Test(arguments: [CGEventType.keyDown, .keyUp])
    func other_keys_pass(type: CGEventType) {
        let d = decide(type, keyCode: 0, swallowingKeyUp: true)
        #expect(!d.swallow)
        #expect(!d.escapeFired)
        #expect(d.swallowingKeyUp, "another key never resets the pending Esc keyUp")
    }

    // MARK: - Hotkey modifiers

    @Test func modifier_flags_map_each_side_to_its_family() {
        #expect(EscapeKeyInterceptor.modifierFlags(of: [.leftShift, .leftControl]) == [.maskShift, .maskControl])
        #expect(EscapeKeyInterceptor.modifierFlags(of: [.rightCommand, .leftOption]) == [.maskCommand, .maskAlternate])
        #expect(EscapeKeyInterceptor.modifierFlags(of: [.rightShift, .rightControl, .rightOption]) == [.maskShift, .maskControl, .maskAlternate])
        #expect(EscapeKeyInterceptor.modifierFlags(of: []) == [])
    }

    @Test func esc_while_holding_only_the_hotkey_fires() {
        let hotkey = EscapeKeyInterceptor.modifierFlags(of: [.leftShift, .leftControl])
        let held: CGEventFlags = [.maskShift, .maskControl, CGEventFlags(rawValue: HotkeyChord.Modifier.leftShift.deviceMaskBit)]
        let d = decide(.keyDown, flags: held.subtracting(hotkey))
        #expect(d.swallow)
        #expect(d.escapeFired)
    }

    @Test func esc_with_a_modifier_beyond_the_hotkey_passes() {
        let hotkey = EscapeKeyInterceptor.modifierFlags(of: [.leftShift, .leftControl])
        let held: CGEventFlags = [.maskShift, .maskControl, .maskCommand]
        let d = decide(.keyDown, flags: held.subtracting(hotkey))
        #expect(!d.swallow)
        #expect(!d.escapeFired)
    }

    // MARK: - Instance state (no tap is installed)

    @Test func starts_disarmed_and_uninstalled() {
        let interceptor = EscapeKeyInterceptor(onEscape: {})
        #expect(!interceptor.isArmed)
        #expect(!interceptor.isInstalled)
        interceptor.isArmed = true
        #expect(interceptor.isArmed)
        interceptor.uninstall()
        #expect(!interceptor.isInstalled)
    }
}
