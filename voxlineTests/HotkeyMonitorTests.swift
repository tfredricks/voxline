import Testing
import CoreGraphics
@testable import voxline

@MainActor
@Suite struct HotkeyMonitorTests {

    typealias Modifier = HotkeyChord.Modifier

    /// Records every scheduled timer; tests fire them by hand.
    @MainActor
    final class ManualTimers: HotkeyTimerScheduling {
        final class Entry: HotkeyTimer {
            let delay: Duration
            let action: @MainActor () -> Void
            private(set) var isInvalidated = false
            private(set) var hasFired = false
            init(delay: Duration, action: @escaping @MainActor () -> Void) {
                self.delay = delay
                self.action = action
            }
            func invalidate() { isInvalidated = true }
            @MainActor func fire() {
                guard !isInvalidated, !hasFired else { return }
                hasFired = true
                action()
            }
        }

        private(set) var entries: [Entry] = []

        func schedule(after delay: Duration, _ fire: @escaping @MainActor () -> Void) -> any HotkeyTimer {
            let entry = Entry(delay: delay, action: fire)
            entries.append(entry)
            return entry
        }

        var pending: [Entry] { entries.filter { !$0.isInvalidated && !$0.hasFired } }

        func pending(_ delay: Duration) -> Entry? { pending.first { $0.delay == delay } }

        func fire(_ delay: Duration) {
            pending(delay)?.fire()
        }
    }

    final class Log {
        var events: [String] = []
    }

    private let d = HotkeyChord.default.keys
    private let c = HotkeyChord.defaultCommand.keys
    private let maxDuration = Duration.seconds(300)

    private func makeMonitor(heldNow: Set<Modifier> = []) -> (HotkeyMonitor, ManualTimers, Log) {
        let timers = ManualTimers()
        let log = Log()
        let monitor = HotkeyMonitor(scheduler: timers, heldNow: { heldNow })
        monitor.onStartRecording = { log.events.append("start:\($0)") }
        monitor.onFinalizeRecording = { log.events.append("finalize:\($0)") }
        monitor.onDiscardRecording = { log.events.append("discard:\($0)") }
        monitor.onBeginPrewarm = { log.events.append("prewarm") }
        monitor.onCancelPrewarm = { log.events.append("cancelPrewarm") }
        monitor.onMaxDurationReached = { log.events.append("cap") }
        return (monitor, timers, log)
    }

    private func flagsEvent(_ held: Set<Modifier>, keyCode: Int64, deviceBits: Bool = true, tagged: Bool = false) -> CGEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: true)!
        event.type = .flagsChanged
        var raw = ModifierFamilies(modifiers: held).cgFlags.rawValue
        if deviceBits { raw = held.reduce(raw) { $0 | $1.deviceMaskBit } }
        event.flags = CGEventFlags(rawValue: raw)
        if tagged { event.setIntegerValueField(.eventSourceUserData, value: SyntheticKeys.tag) }
        return event
    }

    private func keyDownEvent(_ keyCode: Int64, tagged: Bool = false) -> CGEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: true)!
        if tagged { event.setIntegerValueField(.eventSourceUserData, value: SyntheticKeys.tag) }
        return event
    }

    private func press(_ monitor: HotkeyMonitor, _ held: Set<Modifier>, keyCode: Int64 = 56) {
        monitor.receive(.flagsChanged, flagsEvent(held, keyCode: keyCode))
    }

    private func keyDown(_ monitor: HotkeyMonitor, _ keyCode: Int64 = 21) {
        monitor.receive(.keyDown, keyDownEvent(keyCode))
    }

    // MARK: - Constants

    @Test func recording_cap_defaults_to_five_minutes() {
        #expect(HotkeyMonitor().maxRecordingDuration == 300)
    }

    @Test func shortcut_window_is_one_second() {
        #expect(HotkeyMonitor.shortcutWindow == .seconds(1))
    }

    @Test func prewarm_delay_is_150_ms() {
        #expect(HotkeyMonitor.prewarmDelay == .milliseconds(150))
    }

    @Test func monitor_starts_with_default_chords_and_not_suspended() {
        let monitor = HotkeyMonitor()
        #expect(monitor.chords == .default)
        #expect(monitor.isSuspended == false)
        #expect(monitor.isTapInstalled == false)
    }

    @Test func held_now_reads_without_a_tap() {
        let held = ModifierTracker.heldNow()
        #expect(held.isSubset(of: Set(Modifier.allCases)))
    }

    @Test func shortcut_keys_exclude_escape_and_modifiers() {
        #expect(HotkeyMonitor.isShortcutKey(0))
        #expect(HotkeyMonitor.isShortcutKey(21))
        #expect(HotkeyMonitor.isShortcutKey(48))
        #expect(!HotkeyMonitor.isShortcutKey(53))
        for keyCode: Int64 in [54, 55, 56, 58, 59, 60, 61, 62] {
            #expect(!HotkeyMonitor.isShortcutKey(keyCode))
        }
    }

    // MARK: - Delayed prewarm

    @Test func arming_prewarms_only_after_the_delay() {
        let (monitor, timers, log) = makeMonitor()
        press(monitor, [.leftShift])
        #expect(monitor.state == .armed)
        #expect(log.events.isEmpty)
        #expect(timers.pending(HotkeyMonitor.prewarmDelay) != nil)
        timers.fire(HotkeyMonitor.prewarmDelay)
        #expect(log.events == ["prewarm"])
    }

    @Test func release_before_the_delay_drops_the_prewarm_silently() {
        let (monitor, timers, log) = makeMonitor()
        press(monitor, [.leftShift])
        press(monitor, [])
        #expect(monitor.state == .idle)
        #expect(timers.pending.isEmpty)
        #expect(log.events.isEmpty)
    }

    @Test func release_after_the_delay_cancels_the_prewarm() {
        let (monitor, timers, log) = makeMonitor()
        press(monitor, [.leftShift])
        timers.fire(HotkeyMonitor.prewarmDelay)
        press(monitor, [])
        #expect(log.events == ["prewarm", "cancelPrewarm"])
    }

    @Test func typing_a_capital_before_the_delay_never_prewarms() {
        let (monitor, timers, log) = makeMonitor()
        press(monitor, [.leftShift])
        keyDown(monitor, 0)
        press(monitor, [])
        #expect(monitor.state == .idle)
        #expect(timers.pending.isEmpty)
        #expect(log.events.isEmpty)
    }

    @Test func completing_the_chord_before_the_delay_drops_the_prewarm() throws {
        let (monitor, timers, log) = makeMonitor()
        press(monitor, [.leftShift])
        let prewarm = try #require(timers.pending(HotkeyMonitor.prewarmDelay))
        press(monitor, d, keyCode: 59)
        #expect(prewarm.isInvalidated)
        #expect(log.events == ["start:dictation"])
    }

    @Test func completing_the_chord_after_the_prewarm_hands_the_engine_to_start() {
        let (monitor, timers, log) = makeMonitor()
        press(monitor, [.leftShift])
        timers.fire(HotkeyMonitor.prewarmDelay)
        press(monitor, d, keyCode: 59)
        press(monitor, [.leftShift], keyCode: 59)
        #expect(log.events == ["prewarm", "start:dictation", "finalize:dictation"])
    }

    // MARK: - Recording

    @Test func start_schedules_the_window_and_the_cap() {
        let (monitor, timers, log) = makeMonitor()
        press(monitor, d)
        #expect(log.events == ["start:dictation"])
        #expect(monitor.state == .recording(.dictation))
        #expect(timers.pending(HotkeyMonitor.shortcutWindow) != nil)
        #expect(timers.pending(maxDuration) != nil)
    }

    @Test func command_chord_starts_a_command() {
        let (monitor, _, log) = makeMonitor()
        press(monitor, [.leftShift])
        press(monitor, c, keyCode: 58)
        #expect(log.events == ["start:command"])
    }

    @Test func key_inside_the_window_discards_and_cancels_both_timers() {
        let (monitor, timers, log) = makeMonitor()
        press(monitor, d)
        keyDown(monitor)
        #expect(log.events == ["start:dictation", "discard:dictation"])
        #expect(monitor.state == .blocked)
        #expect(timers.pending.isEmpty)
        press(monitor, [])
        #expect(monitor.state == .idle)
        #expect(log.events.count == 2)
    }

    @Test func extra_modifier_inside_the_window_discards() {
        let (monitor, _, log) = makeMonitor()
        press(monitor, d)
        press(monitor, d.union([.leftCommand]), keyCode: 55)
        #expect(log.events == ["start:dictation", "discard:dictation"])
    }

    @Test func keys_after_the_window_are_ignored_and_release_finalizes() {
        let (monitor, timers, log) = makeMonitor()
        press(monitor, d)
        timers.fire(HotkeyMonitor.shortcutWindow)
        keyDown(monitor)
        press(monitor, d.union([.leftCommand]), keyCode: 55)
        #expect(monitor.state == .recording(.dictation))
        press(monitor, [.leftShift], keyCode: 59)
        #expect(log.events == ["start:dictation", "finalize:dictation"])
        #expect(timers.pending.isEmpty)
    }

    @Test func release_cancels_the_window_and_the_cap() {
        let (monitor, timers, log) = makeMonitor()
        press(monitor, d)
        press(monitor, [], keyCode: 59)
        #expect(log.events == ["start:dictation", "finalize:dictation"])
        #expect(timers.pending.isEmpty)
        monitor.recordingFinished()
        #expect(monitor.state == .idle)
    }

    @Test func cap_reports_then_finalizes() {
        let (monitor, timers, log) = makeMonitor()
        press(monitor, d)
        timers.fire(HotkeyMonitor.shortcutWindow)
        timers.fire(maxDuration)
        #expect(log.events == ["start:dictation", "cap", "finalize:dictation"])
        #expect(monitor.state == .finalizing(.dictation))
    }

    @Test func escape_and_modifier_key_downs_never_discard() {
        let (monitor, _, log) = makeMonitor()
        press(monitor, d)
        keyDown(monitor, 53)
        keyDown(monitor, 55)
        keyDown(monitor, 61)
        #expect(log.events == ["start:dictation"])
        #expect(monitor.state == .recording(.dictation))
    }

    @Test func tagged_events_are_ignored() {
        let (monitor, _, log) = makeMonitor()
        monitor.receive(.flagsChanged, flagsEvent(d, keyCode: 59, tagged: true))
        #expect(monitor.state == .idle)
        press(monitor, d)
        monitor.receive(.keyDown, keyDownEvent(9, tagged: true))
        monitor.receive(.flagsChanged, flagsEvent([], keyCode: 59, tagged: true))
        #expect(monitor.state == .recording(.dictation))
        #expect(log.events == ["start:dictation"])
    }

    @Test func generic_only_flags_still_drive_the_chord() {
        let (monitor, timers, log) = makeMonitor()
        monitor.receive(.flagsChanged, flagsEvent([.leftShift], keyCode: 56, deviceBits: false))
        monitor.receive(.flagsChanged, flagsEvent(d, keyCode: 59, deviceBits: false))
        timers.fire(HotkeyMonitor.shortcutWindow)
        monitor.receive(.flagsChanged, flagsEvent([.leftShift], keyCode: 59, deviceBits: false))
        #expect(log.events == ["start:dictation", "finalize:dictation"])
    }

    // MARK: - Input lost

    @Test func tap_disabled_while_recording_finalizes() {
        let (monitor, _, log) = makeMonitor()
        press(monitor, d)
        monitor.receive(.tapDisabledByTimeout, keyDownEvent(0))
        #expect(log.events == ["start:dictation", "finalize:dictation"])
        monitor.recordingFinished()
        #expect(monitor.state == .idle)
    }

    @Test func stop_while_recording_finalizes_and_clears_timers() {
        let (monitor, timers, log) = makeMonitor()
        press(monitor, d)
        monitor.stop()
        #expect(log.events == ["start:dictation", "finalize:dictation"])
        #expect(timers.pending.isEmpty)
    }

    @Test func stop_while_armed_drops_the_pending_prewarm() {
        let (monitor, timers, log) = makeMonitor()
        press(monitor, [.leftShift])
        monitor.stop()
        #expect(monitor.state == .idle)
        #expect(timers.pending.isEmpty)
        #expect(log.events.isEmpty)
    }

    // MARK: - Keys the key interceptor swallowed

    @Test func swallowed_key_while_armed_blocks_and_cancels_the_prewarm() {
        let (monitor, timers, log) = makeMonitor()
        press(monitor, [.leftOption], keyCode: 58)
        #expect(monitor.state == .armed)
        timers.fire(HotkeyMonitor.prewarmDelay)

        monitor.noteSwallowedKeyDown()

        #expect(monitor.state == .blocked)
        #expect(log.events == ["prewarm", "cancelPrewarm"])
        press(monitor, c, keyCode: 56)
        #expect(monitor.state == .blocked)
        press(monitor, [], keyCode: 58)
        #expect(monitor.state == .idle)
        #expect(log.events == ["prewarm", "cancelPrewarm"])
    }

    @Test func swallowed_key_before_the_delay_never_prewarms() {
        let (monitor, timers, log) = makeMonitor()
        press(monitor, [.leftOption], keyCode: 58)
        monitor.noteSwallowedKeyDown()
        #expect(monitor.state == .blocked)
        #expect(timers.pending.isEmpty)
        #expect(log.events.isEmpty)
    }

    @Test func swallowed_key_inside_the_window_discards() {
        let (monitor, timers, log) = makeMonitor()
        press(monitor, d)
        monitor.noteSwallowedKeyDown()
        #expect(log.events == ["start:dictation", "discard:dictation"])
        #expect(monitor.state == .blocked)
        #expect(timers.pending.isEmpty)
    }

    @Test func swallowed_key_after_the_window_keeps_the_recording() {
        let (monitor, timers, log) = makeMonitor()
        press(monitor, d)
        timers.fire(HotkeyMonitor.shortcutWindow)
        monitor.noteSwallowedKeyDown()
        #expect(monitor.state == .recording(.dictation))
        #expect(log.events == ["start:dictation"])
    }

    @Test func swallowed_key_while_idle_changes_nothing() {
        let (monitor, timers, log) = makeMonitor()
        monitor.noteSwallowedKeyDown()
        #expect(monitor.state == .idle)
        #expect(timers.pending.isEmpty)
        #expect(log.events.isEmpty)
        press(monitor, d)
        #expect(log.events == ["start:dictation"])
    }

    @Test func swallowed_key_is_ignored_while_suspended() {
        let (monitor, _, log) = makeMonitor()
        monitor.suspend()
        monitor.noteSwallowedKeyDown()
        #expect(monitor.state == .idle)
        #expect(log.events.isEmpty)
    }

    // MARK: - Suspend and resume

    @Test func suspend_and_resume_toggle_is_suspended() {
        let (monitor, _, _) = makeMonitor()
        monitor.suspend()
        #expect(monitor.isSuspended)
        monitor.resume()
        #expect(!monitor.isSuspended)
    }

    @Test func suspend_while_recording_finalizes_and_ignores_events() {
        let (monitor, _, log) = makeMonitor()
        press(monitor, d)
        monitor.suspend()
        #expect(log.events == ["start:dictation", "finalize:dictation"])
        monitor.recordingFinished()
        press(monitor, [])
        press(monitor, d)
        keyDown(monitor)
        #expect(monitor.state == .idle)
        #expect(log.events.count == 2)
    }

    @Test func resume_with_the_chord_held_never_records() {
        let (monitor, _, log) = makeMonitor(heldNow: HotkeyChord.default.keys)
        monitor.suspend()
        monitor.resume()
        #expect(monitor.state == .blocked)
        press(monitor, d)
        #expect(monitor.state == .blocked)
        press(monitor, [])
        #expect(monitor.state == .idle)
        press(monitor, d)
        #expect(log.events == ["start:dictation"])
    }

    @Test func resume_with_nothing_held_is_idle() {
        let (monitor, _, _) = makeMonitor()
        monitor.suspend()
        monitor.resume()
        #expect(monitor.state == .idle)
    }

    // MARK: - Tap masks

    final class TapAttempts {
        var masks: [CGEventMask] = []
    }

    private let keyEventsMask = CGEventMask(1 << CGEventType.flagsChanged.rawValue) | CGEventMask(1 << CGEventType.keyDown.rawValue)
    private let modifiersOnlyMask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)

    private func plainPort() -> CFMachPort? {
        CFMachPortCreate(kCFAllocatorDefault, { _, _, _, _ in }, nil, nil)
    }

    @Test func masks_prefer_key_events_then_modifiers_only() {
        #expect(HotkeyMonitor.masks == [keyEventsMask, modifiersOnlyMask])
    }

    @Test func first_accepted_mask_wins() {
        var tried: [CGEventMask] = []
        let accepted = HotkeyMonitor.firstAccepted(HotkeyMonitor.masks) { mask -> String? in
            tried.append(mask)
            return mask == modifiersOnlyMask ? "tap" : nil
        }
        #expect(accepted?.tap == "tap")
        #expect(accepted?.mask == modifiersOnlyMask)
        #expect(tried == [keyEventsMask, modifiersOnlyMask])
    }

    @Test func first_mask_accepted_stops_trying() {
        var tried: [CGEventMask] = []
        let accepted = HotkeyMonitor.firstAccepted(HotkeyMonitor.masks) { mask -> Int? in
            tried.append(mask)
            return 1
        }
        #expect(accepted?.mask == keyEventsMask)
        #expect(tried == [keyEventsMask])
    }

    @Test func no_mask_accepted_is_nil() {
        #expect(HotkeyMonitor.firstAccepted(HotkeyMonitor.masks) { _ -> Int? in nil } == nil)
    }

    @Test func start_tries_both_masks_then_throws() {
        let attempts = TapAttempts()
        let monitor = HotkeyMonitor(tapFactory: { mask, _ in
            attempts.masks.append(mask)
            return nil
        })
        #expect(throws: HotkeyMonitorError.accessibilityNotGranted) { try monitor.start() }
        #expect(attempts.masks == [keyEventsMask, modifiersOnlyMask])
        #expect(!monitor.isTapInstalled)
    }

    @Test func start_falls_back_to_a_modifier_only_tap() throws {
        let attempts = TapAttempts()
        let monitor = HotkeyMonitor(
            scheduler: ManualTimers(),
            heldNow: { [] },
            tapFactory: { [self] mask, _ in
                attempts.masks.append(mask)
                return mask == modifiersOnlyMask ? plainPort() : nil
            }
        )
        try monitor.start()
        defer { monitor.stop() }
        #expect(monitor.isTapInstalled)
        #expect(!monitor.observesKeyDown)
        #expect(attempts.masks == [keyEventsMask, modifiersOnlyMask])
    }

    @Test func modifier_only_tap_still_discards_on_an_extra_modifier() throws {
        let timers = ManualTimers()
        let log = Log()
        let monitor = HotkeyMonitor(
            scheduler: timers,
            heldNow: { [] },
            tapFactory: { [self] mask, _ in mask == modifiersOnlyMask ? plainPort() : nil }
        )
        monitor.onStartRecording = { log.events.append("start:\($0)") }
        monitor.onDiscardRecording = { log.events.append("discard:\($0)") }
        try monitor.start()
        defer { monitor.stop() }
        press(monitor, d)
        press(monitor, d.union([.leftCommand]), keyCode: 55)
        #expect(log.events == ["start:dictation", "discard:dictation"])
    }

    @Test func start_with_key_events_observes_key_down() throws {
        let monitor = HotkeyMonitor(scheduler: ManualTimers(), heldNow: { [] }, tapFactory: { [self] _, _ in plainPort() })
        try monitor.start()
        defer { monitor.stop() }
        #expect(monitor.observesKeyDown)
    }

    // MARK: - Chords

    @Test func reassigning_chords_while_armed_resyncs_to_blocked() {
        let (monitor, timers, log) = makeMonitor()
        press(monitor, [.leftShift])
        timers.fire(HotkeyMonitor.prewarmDelay)
        monitor.chords = ChordSet(dictation: .default, command: nil)
        #expect(monitor.state == .blocked)
        #expect(log.events == ["prewarm", "cancelPrewarm"])
        press(monitor, d, keyCode: 59)
        #expect(monitor.state == .blocked)
        press(monitor, [])
        #expect(monitor.state == .idle)
    }

    @Test func reassigning_the_same_chords_while_armed_stays_armed() {
        let (monitor, timers, log) = makeMonitor()
        press(monitor, [.leftShift])
        timers.fire(HotkeyMonitor.prewarmDelay)
        monitor.chords = .default
        #expect(monitor.state == .armed)
        #expect(log.events == ["prewarm"])
        press(monitor, d, keyCode: 59)
        #expect(log.events == ["prewarm", "start:dictation"])
    }

    @Test func turning_command_mode_off_while_recording_a_command_finalizes_it() {
        let (monitor, _, log) = makeMonitor()
        press(monitor, c, keyCode: 58)
        monitor.chords = ChordSet(dictation: .default, command: nil)
        #expect(log.events == ["start:command", "finalize:command"])
        #expect(monitor.state == .finalizing(.command))
        monitor.recordingFinished()
        #expect(monitor.state == .blocked)
        press(monitor, [])
        #expect(monitor.state == .idle)
        #expect(log.events == ["start:command", "finalize:command"])
    }

    @Test func changing_the_recording_chord_finalizes_it() {
        let (monitor, _, log) = makeMonitor()
        press(monitor, d)
        monitor.chords = ChordSet(
            dictation: HotkeyChord(modifierA: .leftShift, modifierB: .rightCommand),
            command: .defaultCommand
        )
        #expect(log.events == ["start:dictation", "finalize:dictation"])
        #expect(monitor.state == .finalizing(.dictation))
    }

    @Test func changing_only_the_other_chord_keeps_the_recording() {
        let (monitor, _, log) = makeMonitor()
        press(monitor, d)
        monitor.chords = ChordSet(
            dictation: HotkeyChord(modifierA: .leftControl, modifierB: .leftShift),
            command: HotkeyChord(modifierA: .leftShift, modifierB: .rightCommand)
        )
        #expect(log.events == ["start:dictation"])
        #expect(monitor.state == .recording(.dictation))
    }

    @Test func reassigning_chords_while_suspended_skips_the_stale_resync() {
        let (monitor, _, _) = makeMonitor()
        press(monitor, [.leftShift])
        monitor.suspend()
        #expect(monitor.state == .idle)
        monitor.chords = ChordSet(dictation: .default, command: nil)
        #expect(monitor.state == .idle)
        #expect(monitor.chords == ChordSet(dictation: .default, command: nil))
    }

    @Test func resuming_during_finalizing_with_the_chord_held_blocks_after_finishing() {
        let (monitor, _, log) = makeMonitor(heldNow: HotkeyChord.default.keys)
        press(monitor, d)
        monitor.suspend()
        monitor.resume()
        #expect(monitor.state == .finalizing(.dictation))
        monitor.recordingFinished()
        #expect(monitor.state == .blocked)
        #expect(log.events == ["start:dictation", "finalize:dictation"])
        press(monitor, [])
        press(monitor, d)
        #expect(log.events == ["start:dictation", "finalize:dictation", "start:dictation"])
    }

    @Test func reassigning_chords_while_idle_stays_idle() {
        let (monitor, _, log) = makeMonitor()
        monitor.chords = ChordSet(dictation: .default, command: nil)
        #expect(monitor.state == .idle)
        press(monitor, c, keyCode: 58)
        #expect(monitor.state == .blocked)
        #expect(log.events.isEmpty)
    }
}
