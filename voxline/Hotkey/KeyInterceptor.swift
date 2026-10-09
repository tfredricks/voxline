import CoreGraphics
import Foundation

/// Swallows Esc while a run can be cancelled, the meeting shortcut while
/// armed, and preset shortcuts while presets are armed, reporting each on
/// the main actor. An active session
/// event tap running on its own thread, so a busy main thread never stalls
/// keyboard input. Everything else passes through untouched.
final class KeyInterceptor: @unchecked Sendable {

    struct Config: Equatable, Sendable {
        /// Mirrors `AppState.isCancellable`.
        var escapeArmed: Bool = false
        var presetsArmed: Bool = false
        var presets: [KeyCombo: UUID] = [:]
        /// Families of both hotkey chords. Esc pressed with only these held
        /// still cancels, since a chord is down while recording.
        var chordFamilies: ModifierFamilies = []
        var meetingArmed: Bool = false
        /// Starts or stops meeting recording. Checked before presets.
        var meetingToggle: KeyCombo? = nil
    }

    enum Fired: Equatable { case escape, preset(UUID), meeting }
    enum Decision: Equatable { case pass, swallow, swallowAndFire(Fired) }

    static let installRetryInterval: Duration = .seconds(10)

    private let onEscape: @MainActor () -> Void
    private let onPreset: @MainActor (UUID) -> Void
    private let onMeeting: @MainActor () -> Void
    private let lock = NSLock()
    private var current = Config()
    private var swallowedDowns: Set<UInt16> = []
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var runLoop: CFRunLoop?
    private var lastInstallFailure: ContinuousClock.Instant?

    init(
        onEscape: @escaping @MainActor () -> Void,
        onPreset: @escaping @MainActor (UUID) -> Void,
        onMeeting: @escaping @MainActor () -> Void = {}
    ) {
        self.onEscape = onEscape
        self.onPreset = onPreset
        self.onMeeting = onMeeting
    }

    var config: Config {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }

    var isInstalled: Bool { lock.withLock { tap != nil } }

    // MARK: - Decisions

    /// Pure decision for one key event. Tagged events always pass. A
    /// swallowed keyDown's keyUp and autorepeats are swallowed too, so the
    /// focused app never sees half of a press.
    static func decide(
        isKeyDown: Bool,
        keyCode: UInt16,
        flags: CGEventFlags,
        isAutorepeat: Bool,
        isSynthetic: Bool,
        config: Config,
        swallowedDowns: Set<UInt16>
    ) -> (decision: Decision, swallowedDowns: Set<UInt16>) {
        if isSynthetic { return (.pass, swallowedDowns) }
        var downs = swallowedDowns
        if !isKeyDown {
            return downs.remove(keyCode) != nil ? (.swallow, downs) : (.pass, downs)
        }
        if isAutorepeat, downs.contains(keyCode) { return (.swallow, downs) }
        let families = ModifierFamilies(flags: flags)
        if keyCode == KeyCombo.escapeKeyCode, config.escapeArmed, families.subtracting(config.chordFamilies).isEmpty {
            downs.insert(keyCode)
            return (.swallowAndFire(.escape), downs)
        }
        if config.meetingArmed, let toggle = config.meetingToggle, toggle == KeyCombo(keyCode: keyCode, modifiers: families) {
            downs.insert(keyCode)
            return (isAutorepeat ? .swallow : .swallowAndFire(.meeting), downs)
        }
        if config.presetsArmed, let id = config.presets[KeyCombo(keyCode: keyCode, modifiers: families)] {
            downs.insert(keyCode)
            return (isAutorepeat ? .swallow : .swallowAndFire(.preset(id)), downs)
        }
        downs.remove(keyCode)
        return (.pass, downs)
    }

    /// Combo-to-id map for `Config.presets`. The first of duplicate combos
    /// wins, and rows that can't fire (no shortcut recorded, no ⌘⌥⌃, Esc, or
    /// a blank instruction) are left out so their keys always pass.
    static func presetMap(_ presets: [PresetShortcut]) -> [KeyCombo: UUID] {
        presets.reduce(into: [:]) { map, preset in
            guard !preset.needsShortcut,
                  preset.combo.keyCode != KeyCombo.escapeKeyCode,
                  !preset.instruction.isBlank,
                  map[preset.combo] == nil
            else { return }
            map[preset.combo] = preset.id
        }
    }

    /// Presets fire only while the tap is installed, no Settings recorder is
    /// capturing a shortcut, and voxline isn't frontmost, so its own fields
    /// still receive ⌥-typed characters.
    static func presetsArmed(installed: Bool, capturingShortcut: Bool, voxlineIsFrontmost: Bool) -> Bool {
        installed && !capturingShortcut && !voxlineIsFrontmost
    }

    static func shouldAttemptInstall(lastFailure: ContinuousClock.Instant?, now: ContinuousClock.Instant) -> Bool {
        guard let lastFailure else { return true }
        return now - lastFailure >= installRetryInterval
    }

    // MARK: - Lifecycle

    /// Creates the tap on a dedicated thread and waits until it is running.
    /// False when the tap can't be created, in which case Esc cancel and
    /// presets are unavailable; after a failure, further attempts within
    /// `installRetryInterval` return false without trying.
    @discardableResult
    func install() -> Bool {
        guard !isInstalled else { return true }
        let attempt = lock.withLock { Self.shouldAttemptInstall(lastFailure: lastInstallFailure, now: .now) }
        guard attempt else { return false }

        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            runTap(signalling: ready)
        }
        thread.name = "voxline.key-interceptor"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()

        let installed = isInstalled
        let firstFailure = lock.withLock { () -> Bool in
            defer { lastInstallFailure = installed ? nil : .now }
            return !installed && lastInstallFailure == nil
        }
        if installed {
            AppLog.hotkey.info("key interceptor installed")
        } else if firstFailure {
            AppLog.hotkey.error("key interceptor: tap creation failed; Esc cancel and presets unavailable")
        }
        return installed
    }

    func uninstall() {
        let installed = lock.withLock { () -> (port: CFMachPort, source: CFRunLoopSource?, loop: CFRunLoop?)? in
            defer {
                self.tap = nil
                self.source = nil
                self.runLoop = nil
                self.swallowedDowns = []
            }
            return self.tap.map { ($0, self.source, self.runLoop) }
        }
        guard let installed else { return }
        CGEvent.tapEnable(tap: installed.port, enable: false)
        if let loop = installed.loop, let source = installed.source {
            CFRunLoopRemoveSource(loop, source, .commonModes)
        }
        CFMachPortInvalidate(installed.port)
        if let loop = installed.loop { CFRunLoopStop(loop) }
        AppLog.hotkey.info("key interceptor removed")
    }

    // MARK: - Tap thread

    /// The thread's closure keeps `self` alive until the run loop stops, so
    /// the unretained refcon handed to the tap stays valid for every callback.
    private func runTap(signalling ready: DispatchSemaphore) {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: Self.tapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            ready.signal()
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        let runLoop = CFRunLoopGetCurrent()
        CFRunLoopAddSource(runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        lock.withLock {
            self.tap = tap
            self.source = source
            self.runLoop = runLoop
            self.swallowedDowns = []
        }
        ready.signal()
        CFRunLoopRun()
    }

    private static let tapCallback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let interceptor = Unmanaged<KeyInterceptor>.fromOpaque(refcon).takeUnretainedValue()
        switch type {
        case .keyDown, .keyUp:
            return interceptor.handle(isKeyDown: type == .keyDown, event: event) ? nil : Unmanaged.passUnretained(event)
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            interceptor.reenable()
            return Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    /// True when the event is swallowed.
    private func handle(isKeyDown: Bool, event: CGEvent) -> Bool {
        let isSynthetic = SyntheticKeys.isTagged(event)
        let isAutorepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let decision = lock.withLock { () -> Decision in
            let result = Self.decide(
                isKeyDown: isKeyDown,
                keyCode: keyCode,
                flags: flags,
                isAutorepeat: isAutorepeat,
                isSynthetic: isSynthetic,
                config: current,
                swallowedDowns: swallowedDowns
            )
            swallowedDowns = result.swallowedDowns
            return result.decision
        }
        switch decision {
        case .pass:
            return false
        case .swallow:
            return true
        case .swallowAndFire(let fired):
            let onEscape = onEscape
            let onPreset = onPreset
            let onMeeting = onMeeting
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    switch fired {
                    case .escape: onEscape()
                    case .preset(let id): onPreset(id)
                    case .meeting: onMeeting()
                    }
                }
            }
            return true
        }
    }

    /// A disabled tap may have missed the keyUps it was waiting for.
    private func reenable() {
        let tap = lock.withLock { () -> CFMachPort? in
            swallowedDowns = []
            return self.tap
        }
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        AppLog.hotkey.debug("key interceptor re-enabled")
    }
}

extension PresetShortcut {
    /// True until a shortcut with ⌘, ⌥, or ⌃ is recorded. "Add preset"
    /// creates rows in this state, and they never fire.
    var needsShortcut: Bool { combo.modifiers.isDisjoint(with: [.command, .option, .control]) }
}
