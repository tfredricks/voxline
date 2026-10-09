import AppKit
import CoreGraphics
import Foundation

/// A scheduled one-shot the monitor can cancel.
protocol HotkeyTimer: AnyObject {
    func invalidate()
}

extension Timer: HotkeyTimer {}

/// Schedules the monitor's one-shot timers. A seam so tests fire them by hand.
protocol HotkeyTimerScheduling {
    @MainActor func schedule(after delay: Duration, _ fire: @escaping @MainActor () -> Void) -> any HotkeyTimer
}

/// Timers on `RunLoop.main` in `.common` mode, so they keep firing while a
/// menu is open or a window is being dragged (issue 20).
struct RunLoopTimerScheduler: HotkeyTimerScheduling {
    @MainActor func schedule(after delay: Duration, _ fire: @escaping @MainActor () -> Void) -> any HotkeyTimer {
        let timer = Timer(timeInterval: delay / .seconds(1), repeats: false) { _ in
            MainActor.assumeIsolated { fire() }
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}

/// Drives a HotkeyStateMachine from real OS events. Owns a listen-only
/// session tap on flagsChanged and keyDown, the recording cap, the shortcut
/// window, and the prewarm delay.
@MainActor
final class HotkeyMonitor {

    /// A key or an extra modifier this soon after a recording starts means
    /// the chord was the start of an OS shortcut, and the recording is dropped.
    static let shortcutWindow: Duration = .seconds(1)
    /// Arming waits this long before warming the microphone, so a capital
    /// letter typed with a shared Shift never starts it.
    static let prewarmDelay: Duration = .milliseconds(150)

    private nonisolated static let escapeKeyCode: Int64 = 53
    private nonisolated static let flagsChangedMask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
    private nonisolated static let keyDownMask = CGEventMask(1 << CGEventType.keyDown.rawValue)

    /// Tap masks in order of preference. Some configurations refuse key
    /// events to a listen-only tap without Input Monitoring; the
    /// modifier-only tap still drives both chords, and its shortcut window
    /// then sees extra modifiers but not other keys.
    nonisolated static let masks: [CGEventMask] = [flagsChangedMask | keyDownMask, flagsChangedMask]

    /// Creates a listen-only tap for `mask` whose callback receives `userInfo`; nil when refused.
    typealias TapFactory = @MainActor (_ mask: CGEventMask, _ userInfo: UnsafeMutableRawPointer) -> CFMachPort?

    var onStartRecording: ((CaptureKind) -> Void)?
    var onFinalizeRecording: ((CaptureKind) -> Void)?
    /// The recording was the start of a shortcut. Runs with the machine
    /// already `blocked`; nothing about it should reach the user.
    var onDiscardRecording: ((CaptureKind) -> Void)?
    /// Fires `prewarmDelay` after arming, unless a key, a release, or the
    /// full chord comes first. Runs on the main actor.
    var onBeginPrewarm: (() -> Void)?
    /// Arming ended without a recording after `onBeginPrewarm` had fired.
    var onCancelPrewarm: (() -> Void)?

    var isTapInstalled: Bool { eventTap != nil }

    /// Recording cap: a recording stops here even while the chord is held.
    var maxRecordingDuration: TimeInterval = 300
    /// Fires on the main actor just before the cap stops a recording.
    var onMaxDurationReached: (() -> Void)?

    /// Setting it resyncs the machine against the keys held now, so a chord
    /// change never starts a recording from keys that are already down.
    var chords: ChordSet = .default {
        didSet {
            machine.chords = chords
            feed(.resync(tracker.held))
        }
    }

    /// While suspended the tap stays installed and every event is ignored.
    private(set) var isSuspended = false

    /// False when the installed tap fell back to modifiers only.
    private(set) var observesKeyDown = false

    var state: HotkeyStateMachine.State { machine.state }

    private let machine = HotkeyStateMachine()
    private var tracker = ModifierTracker()
    private let scheduler: any HotkeyTimerScheduling
    private let heldNow: () -> Set<HotkeyChord.Modifier>
    private let tapFactory: TapFactory
    private var didLogModifierOnlyTap = false
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var maxDurationTimer: (any HotkeyTimer)?
    private var shortcutWindowTimer: (any HotkeyTimer)?
    private var prewarmTimer: (any HotkeyTimer)?
    private var prewarmFired = false

    init(
        scheduler: any HotkeyTimerScheduling = RunLoopTimerScheduler(),
        heldNow: @escaping () -> Set<HotkeyChord.Modifier> = ModifierTracker.heldNow,
        tapFactory: @escaping TapFactory = HotkeyMonitor.makeListenOnlyTap
    ) {
        self.scheduler = scheduler
        self.heldNow = heldNow
        self.tapFactory = tapFactory
    }

    /// The first of `masks` that `create` accepts, with what it created.
    nonisolated static func firstAccepted<Tap>(
        _ masks: [CGEventMask],
        create: (CGEventMask) -> Tap?
    ) -> (tap: Tap, mask: CGEventMask)? {
        for mask in masks {
            if let tap = create(mask) { return (tap, mask) }
        }
        return nil
    }

    static func makeListenOnlyTap(mask: CGEventMask, userInfo: UnsafeMutableRawPointer) -> CFMachPort? {
        CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: HotkeyMonitor.tapCallback,
            userInfo: userInfo
        )
    }

    /// A keyDown that can be the key of an OS shortcut: neither Esc nor a modifier.
    nonisolated static func isShortcutKey(_ keyCode: Int64) -> Bool {
        keyCode != escapeKeyCode && !ModifierTracker.modifierKeyCodes.contains(keyCode)
    }

    // MARK: - Lifecycle

    /// Install the tap and resync with the keys held now. Falls back to a
    /// modifier-only tap when key events are refused. Throws if no tap can
    /// be created (Accessibility not granted).
    func start() throws {
        guard eventTap == nil else { return }
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let installed = Self.firstAccepted(Self.masks, create: { tapFactory($0, userInfo) }) else {
            throw HotkeyMonitorError.accessibilityNotGranted
        }
        let tap = installed.tap
        observesKeyDown = installed.mask & Self.keyDownMask != 0
        if !observesKeyDown && !didLogModifierOnlyTap {
            didLogModifierOnlyTap = true
            AppLog.hotkey.notice("hotkey tap without key events — shortcut window limited to modifiers")
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        eventTap = tap
        runLoopSource = source
        CGEvent.tapEnable(tap: tap, enable: true)
        resyncWithHeldKeys()
        AppLog.hotkey.info("monitor installed")
    }

    /// Ends any recording as if the chord were released (issue 12), then
    /// removes the tap.
    func stop() {
        feed(.inputLost)
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let src = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
        eventTap = nil
        runLoopSource = nil
        cancelRecordingTimers()
        cancelPrewarmTimer()
        prewarmFired = false
    }

    /// Stops reacting to keys, ending any recording, until `resume()`.
    func suspend() {
        guard !isSuspended else { return }
        isSuspended = true
        feed(.inputLost)
    }

    /// Reacts to keys again. A chord still held lands in `blocked`.
    func resume() {
        guard isSuspended else { return }
        isSuspended = false
        resyncWithHeldKeys()
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

    // MARK: - Events

    // The run-loop source is on CFRunLoopGetMain(), so the callback is already
    // on the main thread. Events are handled inline, not through a Task, so
    // flagsChanged and keyDown stay in hardware order.
    private static let tapCallback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
        MainActor.assumeIsolated {
            monitor.receive(type, event)
        }
        return Unmanaged.passUnretained(event)
    }

    /// One tap event. Events voxline posted itself, Esc, and modifier
    /// keyDowns never reach the machine; nothing but the type, flags, and
    /// keycode is read.
    func receive(_ type: CGEventType, _ event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            let reason = (type == .tapDisabledByTimeout) ? "timeout" : "user-input"
            AppLog.hotkey.debug("tap re-enabled (\(reason))")
            guard !isSuspended else { return }
            feed(.inputLost)
        case .flagsChanged:
            guard !isSuspended, !SyntheticKeys.isTagged(event) else { return }
            let held = tracker.update(flags: event.flags, keyCode: event.getIntegerValueField(.keyboardEventKeycode))
            feed(.modifiersChanged(held))
        case .keyDown:
            guard !isSuspended,
                  !SyntheticKeys.isTagged(event),
                  Self.isShortcutKey(event.getIntegerValueField(.keyboardEventKeycode))
            else { return }
            feed(.keyDown)
        default:
            break
        }
    }

    private func resyncWithHeldKeys() {
        let held = heldNow()
        tracker.reset(to: held)
        feed(.resync(held))
    }

    // MARK: - Routing outputs

    private func feed(_ input: HotkeyStateMachine.Input) {
        for output in machine.handle(input) {
            switch output {
            case .startRecording(let kind):
                cancelPrewarmTimer()
                prewarmFired = false
                scheduleRecordingTimers()
                onStartRecording?(kind)
            case .finalizeRecording(let kind):
                cancelRecordingTimers()
                onFinalizeRecording?(kind)
            case .discardRecording(let kind):
                cancelRecordingTimers()
                onDiscardRecording?(kind)
            case .beginPrewarm:
                schedulePrewarm()
            case .cancelPrewarm:
                cancelPrewarmTimer()
                if prewarmFired {
                    prewarmFired = false
                    onCancelPrewarm?()
                }
            }
        }
    }

    private func schedulePrewarm() {
        cancelPrewarmTimer()
        prewarmFired = false
        prewarmTimer = scheduler.schedule(after: Self.prewarmDelay) { [weak self] in
            guard let self else { return }
            self.prewarmTimer = nil
            self.prewarmFired = true
            self.onBeginPrewarm?()
        }
    }

    private func cancelPrewarmTimer() {
        prewarmTimer?.invalidate()
        prewarmTimer = nil
    }

    private func scheduleRecordingTimers() {
        cancelRecordingTimers()
        maxDurationTimer = scheduler.schedule(after: .seconds(maxRecordingDuration)) { [weak self] in
            guard let self else { return }
            self.maxDurationTimer = nil
            self.onMaxDurationReached?()
            self.feed(.maxDurationElapsed)
        }
        shortcutWindowTimer = scheduler.schedule(after: Self.shortcutWindow) { [weak self] in
            guard let self else { return }
            self.shortcutWindowTimer = nil
            self.feed(.shortcutWindowClosed)
        }
    }

    private func cancelRecordingTimers() {
        maxDurationTimer?.invalidate()
        maxDurationTimer = nil
        shortcutWindowTimer?.invalidate()
        shortcutWindowTimer = nil
    }

    deinit {
        // Disable the CGEventTap so the C callback can no longer fire and
        // read our refcon (which would be a use-after-free), and tear down
        // the run-loop source. Synchronous; doesn't touch @MainActor state.
        // The timers hold the monitor weakly and need no teardown.
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
        }
    }
}

enum HotkeyMonitorError: Error {
    case accessibilityNotGranted
}
