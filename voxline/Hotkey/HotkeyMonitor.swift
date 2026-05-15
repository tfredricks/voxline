import AppKit
import CoreGraphics
import Foundation
import IOKit.hidsystem

/// Drives a HotkeyStateMachine from real OS events. Owns a session-level
/// CGEventTap and the max-duration fail-safe timer.
@MainActor
final class HotkeyMonitor {

    /// Observer notified when the state machine produces effects.
    /// Runs on the main actor.
    var onStartRecording: (() -> Void)?
    var onFinalizeRecording: (() -> Void)?

    /// Optional debug observer — fired whenever the state machine state or
    /// tap-installation status changes. Used by the menu-bar debug section.
    var onDebugStateChanged: ((HotkeyStateMachine.State, Bool) -> Void)?

    /// Optional debug observer — fired with a label describing what triggered
    /// the most recent finalize (chord-release / tap-disabled / max-duration).
    /// Lets the Debug window explain a too-short recording.
    var onDebugFinalizeReason: ((String) -> Void)?

    /// Snapshot of state-machine state for diagnostics.
    var currentState: HotkeyStateMachine.State { machine.state }
    var isTapInstalled: Bool { eventTap != nil }

    /// Maximum recording duration (spec §4.1 fail-safe). Configurable.
    var maxRecordingDuration: TimeInterval = 60.0

    /// Active chord. Read by the tap callback to test the right device-mask bits.
    /// Defaults to .default; AppCoordinator overrides from AppSettings on launch.
    var chord: HotkeyChord = .default

    private let machine = HotkeyStateMachine()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var maxDurationTimer: Timer?

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
        onDebugStateChanged?(machine.state, true)
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

    /// Update the active chord at runtime. No tap rebuild required.
    func update(chord: HotkeyChord) {
        self.chord = chord
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
                monitor.feed(.flagsChanged(modAFlag: modA, modBFlag: modB))
            }
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            let reason = (type == .tapDisabledByTimeout) ? "timeout" : "user-input"
            MainActor.assumeIsolated {
                if let tap = monitor.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                AppLog.hotkey.debug("tap re-enabled (\(reason, privacy: .public))")
                monitor.feed(.tapDisabled)
            }
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    // MARK: - Routing inputs through the machine

    private func feed(_ input: HotkeyStateMachine.Input) {
        let stateBefore = machine.state
        let outputs = machine.handle(input)
        for output in outputs {
            switch output {
            case .startRecording:
                scheduleMaxDurationTimer()
                onStartRecording?()
            case .finalizeRecording:
                cancelMaxDurationTimer()
                if stateBefore == .recording {
                    onDebugFinalizeReason?(reasonLabel(for: input))
                }
                onFinalizeRecording?()
            }
        }
        onDebugStateChanged?(machine.state, eventTap != nil)
    }

    private func reasonLabel(for input: HotkeyStateMachine.Input) -> String {
        switch input {
        case .flagsChanged(let a, let b):
            return "chord-release (modA=\(a), modB=\(b))"
        case .maxDurationElapsed: return "max-duration"
        case .tapDisabled:        return "tap-disabled"
        case .recordingFinished:  return "recording-finished"
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
