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

    /// Optional debug observer — fired for every flagsChanged event observed,
    /// with a one-line summary. Used to diagnose phantom modifier releases
    /// coming from keyboard remappers, Sticky Keys, Mission Control, etc.
    var onDebugFlagEvent: ((String) -> Void)?

    /// Snapshot of state-machine state for diagnostics.
    var currentState: HotkeyStateMachine.State { machine.state }
    var isTapInstalled: Bool { eventTap != nil }

    /// Maximum recording duration (spec §4.1 fail-safe). Configurable.
    var maxRecordingDuration: TimeInterval = 60.0

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

        switch type {
        case .flagsChanged:
            let flags = event.flags
            // CGEvent.flags exposes per-device modifier bits
            // (NX_DEVICELCTLKEYMASK / NX_DEVICELALTKEYMASK) that distinguish
            // left vs right modifiers, unlike the coalesced
            // CGEventFlags.maskControl / .maskAlternate.
            let leftCtrl = flags.contains(CGEventFlags(rawValue: UInt64(NX_DEVICELCTLKEYMASK)))
            let leftOpt  = flags.contains(CGEventFlags(rawValue: UInt64(NX_DEVICELALTKEYMASK)))
            let anyCtrl  = flags.contains(.maskControl)
            let anyOpt   = flags.contains(.maskAlternate)
            let raw = String(flags.rawValue, radix: 16)
            let line = "raw=0x\(raw) leftCtrl=\(leftCtrl) leftOpt=\(leftOpt) anyCtrl=\(anyCtrl) anyOpt=\(anyOpt)"
            Task { @MainActor in
                monitor.onDebugFlagEvent?(line)
                monitor.feed(.flagsChanged(leftCtrlDown: leftCtrl, leftOptDown: leftOpt))
            }
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // Re-enable the tap and signal a defensive finalize.
            if let tap = monitor.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            Task { @MainActor in
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
        case .flagsChanged(let ctrl, let opt):
            return "chord-release (ctrl=\(ctrl), opt=\(opt))"
        case .maxDurationElapsed: return "max-duration"
        case .tapDisabled:        return "tap-disabled"
        case .recordingFinished:  return "recording-finished"
        }
    }

    private func scheduleMaxDurationTimer() {
        maxDurationTimer?.invalidate()
        maxDurationTimer = Timer.scheduledTimer(withTimeInterval: maxRecordingDuration, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.feed(.maxDurationElapsed) }
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
