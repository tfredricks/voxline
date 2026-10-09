import CoreGraphics
import Foundation

/// Swallows Esc while armed and reports it on the main actor. An active
/// session event tap running on its own thread, so a busy main thread never
/// stalls keyboard input. Everything else, and everything while disarmed,
/// passes through untouched.
final class EscapeKeyInterceptor: @unchecked Sendable {

    static let escapeKeyCode: Int64 = 53

    private static let blockingModifiers: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]

    private let onEscape: @MainActor () -> Void
    private let lock = NSLock()
    private var armed = false
    private var swallowingKeyUp = false
    private var ignoredModifiers: CGEventFlags = []
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var runLoop: CFRunLoop?
    private var lastInstallFailed = false

    init(onEscape: @escaping @MainActor () -> Void) {
        self.onEscape = onEscape
    }

    /// Mirrors `AppState.isCancellable`.
    var isArmed: Bool {
        get { lock.withLock { armed } }
        set { lock.withLock { armed = newValue } }
    }

    /// Modifier families the user holds for the hotkey itself. Esc pressed
    /// with only these held still cancels; any other modifier lets it pass.
    var hotkeyModifiers: CGEventFlags {
        get { lock.withLock { ignoredModifiers } }
        set { lock.withLock { ignoredModifiers = newValue } }
    }

    var isInstalled: Bool { lock.withLock { tap != nil } }

    /// Pure decision for one key event. A swallowed Esc keyDown arms
    /// swallowing of its keyUp and of its autorepeats, so the focused app
    /// never sees half of a press.
    static func shouldSwallow(
        type: CGEventType,
        keyCode: Int64,
        flags: CGEventFlags,
        armed: Bool,
        swallowingKeyUp: Bool
    ) -> (swallow: Bool, escapeFired: Bool, swallowingKeyUp: Bool) {
        guard keyCode == escapeKeyCode else { return (false, false, swallowingKeyUp) }
        switch type {
        case .keyDown where swallowingKeyUp:
            return (true, false, true)
        case .keyDown where armed && flags.isDisjoint(with: blockingModifiers):
            return (true, true, true)
        case .keyUp where swallowingKeyUp:
            return (true, false, false)
        default:
            return (false, false, swallowingKeyUp)
        }
    }

    static func modifierFlags(of modifiers: [HotkeyChord.Modifier]) -> CGEventFlags {
        modifiers.reduce(into: []) { flags, modifier in
            switch modifier {
            case .leftControl, .rightControl: flags.insert(.maskControl)
            case .leftOption, .rightOption:   flags.insert(.maskAlternate)
            case .leftCommand, .rightCommand: flags.insert(.maskCommand)
            case .leftShift, .rightShift:     flags.insert(.maskShift)
            }
        }
    }

    // MARK: - Lifecycle

    /// Creates the tap on a dedicated thread and waits until it is running.
    /// False when the tap can't be created; Esc cancel is then unavailable.
    @discardableResult
    func install() -> Bool {
        guard !isInstalled else { return true }
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            runTap(signalling: ready)
        }
        thread.name = "voxline.escape-tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()

        let installed = isInstalled
        let shouldLog = lock.withLock { () -> Bool in
            defer { lastInstallFailed = !installed }
            return !installed && !lastInstallFailed
        }
        if installed {
            AppLog.hotkey.info("escape interceptor installed")
        } else if shouldLog {
            AppLog.hotkey.error("escape interceptor: tap creation failed; Esc cancel unavailable")
        }
        return installed
    }

    func uninstall() {
        let installed = lock.withLock { () -> (port: CFMachPort, source: CFRunLoopSource?, loop: CFRunLoop?)? in
            defer {
                self.tap = nil
                self.source = nil
                self.runLoop = nil
                self.swallowingKeyUp = false
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
        AppLog.hotkey.info("escape interceptor removed")
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
        }
        ready.signal()
        CFRunLoopRun()
    }

    private static let tapCallback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let interceptor = Unmanaged<EscapeKeyInterceptor>.fromOpaque(refcon).takeUnretainedValue()
        switch type {
        case .keyDown, .keyUp:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            return interceptor.handle(type: type, keyCode: keyCode, flags: event.flags) ? nil : Unmanaged.passUnretained(event)
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            interceptor.reenable()
            return Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func handle(type: CGEventType, keyCode: Int64, flags: CGEventFlags) -> Bool {
        let decision = lock.withLock { () -> (swallow: Bool, escapeFired: Bool, swallowingKeyUp: Bool) in
            let decision = Self.shouldSwallow(
                type: type,
                keyCode: keyCode,
                flags: flags.subtracting(ignoredModifiers),
                armed: armed,
                swallowingKeyUp: swallowingKeyUp
            )
            swallowingKeyUp = decision.swallowingKeyUp
            return decision
        }
        if decision.escapeFired {
            let onEscape = onEscape
            DispatchQueue.main.async {
                MainActor.assumeIsolated { onEscape() }
            }
        }
        return decision.swallow
    }

    /// A disabled tap may have missed the keyUp it was waiting for.
    private func reenable() {
        let tap = lock.withLock { () -> CFMachPort? in
            swallowingKeyUp = false
            return self.tap
        }
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        AppLog.hotkey.debug("escape interceptor re-enabled")
    }
}
