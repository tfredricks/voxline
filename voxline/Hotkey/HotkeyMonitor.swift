import AppKit
import CoreGraphics
import Foundation
import IOKit.hidsystem

/// Drives a HotkeyStateMachine from real OS events. Owns a session-level
/// CGEventTap and the max-duration fail-safe timer.
@MainActor
final class HotkeyMonitor {

    /// Observer notified when the state machine produces `startRecording`.
    /// The `Bool` is whether the command modifier was held at recording start
    /// (command gesture) vs plain dictation. Runs on the main actor.
    var onStartRecording: ((Bool) -> Void)?
    var onFinalizeRecording: (() -> Void)?
    /// One chord modifier went down — warm the audio engine. Runs on the main actor.
    var onBeginPrewarm: (() -> Void)?
    /// The armed modifier was released without completing the chord.
    var onCancelPrewarm: (() -> Void)?

    var isTapInstalled: Bool { eventTap != nil }

    /// Maximum recording duration fail-safe. Configurable.
    var maxRecordingDuration: TimeInterval = 60.0

    /// Active chord. Read by the tap callback to test the right device-mask bits.
    /// Defaults to .default; AppCoordinator overrides from AppSettings on launch.
    var chord: HotkeyChord = .default

    /// Command modifier sampled at recording start. `nil` = command mode off.
    /// Defaults to `.leftOption`; AppCoordinator overrides from AppSettings on
    /// launch and on every settings change.
    var commandModifier: HotkeyChord.Modifier? = .leftOption

    /// Latest observed command-modifier state, updated on EVERY flagsChanged
    /// (mirroring `HotkeyStateMachine.lastFlags`) so the resume-on-
    /// `recordingFinished` path — which emits `startRecording` with no live
    /// event — samples the current value.
    private var lastCommandFlag = false

    private let machine = HotkeyStateMachine()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var maxDurationTimer: Timer?

    /// Pure sampling predicate — testable without a CGEventTap. Whether the
    /// command modifier is held in `flags`. A modifier that collides with a
    /// chord key (or `nil`) is treated as "not a command", so command mode can
    /// never make plain dictation impossible.
    nonisolated static func commandIsHeld(in flags: CGEventFlags, chord: HotkeyChord, commandModifier: HotkeyChord.Modifier?) -> Bool {
        guard let cmd = commandModifier,
              cmd != chord.modifierA,
              cmd != chord.modifierB else { return false }
        return cmd.isHeld(in: flags)
    }

    // MARK: - Lifecycle

    /// Install the tap and observers. Throws if Accessibility is not granted.
    func start() throws {
        guard eventTap == nil else { return }
        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: HotkeyMonitor.tapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            throw HotkeyMonitorError.accessibilityNotGranted
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        eventTap = tap
        runLoopSource = source
        CGEvent.tapEnable(tap: tap, enable: true)
        AppLog.hotkey.info("monitor installed")
    }

    func stop() {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let src = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
        eventTap = nil
        runLoopSource = nil

        maxDurationTimer?.invalidate()
        maxDurationTimer = nil
    }

    /// External signal that transcription has finished and we can return to idle.
    func recordingFinished() {
        feed(.recordingFinished)
        // The synthetic Cmd+V posted by the paste flow can fire
        // kCGEventTapDisabledByUserInput against our own session tap. The
        // tap-disabled callback already calls tapEnable, but on some macOS
        // builds the tap stays unresponsive until it's re-enabled again
        // *after* the synthetic-event burst settles. Force-re-enable here so
        // the next chord press is reliably observed.
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    // MARK: - Tap callback

    private static let tapCallback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()

        // The runloop source is registered with CFRunLoopGetMain(), so this
        // callback is already on the main thread. Process inline via
        // MainActor.assumeIsolated rather than hopping through Task { @MainActor }
        // — unstructured Tasks don't preserve submission order, and modifier
        // events from the same hardware source must remain ordered.
        switch type {
        case .flagsChanged:
            let flags = event.flags
            MainActor.assumeIsolated {
                let chord = monitor.chord
                let modA = flags.contains(CGEventFlags(rawValue: chord.modifierA.deviceMaskBit))
                let modB = flags.contains(CGEventFlags(rawValue: chord.modifierB.deviceMaskBit))
                monitor.lastCommandFlag = HotkeyMonitor.commandIsHeld(
                    in: flags, chord: chord, commandModifier: monitor.commandModifier
                )
                monitor.feed(.flagsChanged(modAFlag: modA, modBFlag: modB))
            }
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            let reason = (type == .tapDisabledByTimeout) ? "timeout" : "user-input"
            MainActor.assumeIsolated {
                if let tap = monitor.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                AppLog.hotkey.debug("tap re-enabled (\(reason))")
                monitor.feed(.tapDisabled)
            }
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    // MARK: - Routing inputs through the machine

    private func feed(_ input: HotkeyStateMachine.Input) {
        let outputs = machine.handle(input)
        for output in outputs {
            switch output {
            case .startRecording:
                scheduleMaxDurationTimer()
                onStartRecording?(lastCommandFlag)
            case .finalizeRecording:
                cancelMaxDurationTimer()
                onFinalizeRecording?()
            case .beginPrewarm:
                onBeginPrewarm?()
            case .cancelPrewarm:
                onCancelPrewarm?()
            }
        }
    }

    private func scheduleMaxDurationTimer() {
        maxDurationTimer?.invalidate()
        maxDurationTimer = Timer.scheduledTimer(withTimeInterval: maxRecordingDuration, repeats: false) { [weak self] _ in
            // Timer was scheduled from a @MainActor context, so its callback
            // fires on the main runloop. Stay synchronous to keep the
            // .maxDurationElapsed signal ordered with subsequent flagsChanged
            // events from the tap.
            MainActor.assumeIsolated {
                self?.feed(.maxDurationElapsed)
            }
        }
    }

    private func cancelMaxDurationTimer() {
        maxDurationTimer?.invalidate()
        maxDurationTimer = nil
    }

    deinit {
        // Disable the CGEventTap so the C callback can no longer fire and
        // read our refcon (which would be a use-after-free), and tear down
        // the run-loop source. Synchronous; doesn't touch @MainActor state.
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
        }
        maxDurationTimer?.invalidate()
    }
}

enum HotkeyMonitorError: Error {
    case accessibilityNotGranted
}
