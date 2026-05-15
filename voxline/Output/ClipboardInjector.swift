// voxline/Output/ClipboardInjector.swift
import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics

/// Polled by ClipboardInjector to gate the synthetic Cmd+V on the user
/// physically releasing the chord. Production impl wraps CGEventSource;
/// tests fake it.
protocol ModifierGate: Sendable {
    /// True iff Left-Ctrl OR Left-Option is currently physically held.
    func chordIsHeld() -> Bool
    /// Synthesize a flagsChanged that clears Left-Ctrl + Left-Option.
    /// Used after the release-timeout elapses.
    func forceClearChord()
}

/// Posts synthetic key events. Wraps CGEvent.post in production; faked in tests.
protocol KeyEventPosting: Sendable {
    func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags)
}

/// Resolves the physical key currently producing "v" in the active keyboard
/// layout. Tests fake this so we do not bake US-ANSI assumptions into the
/// injector behavior.
protocol PasteKeyResolving: Sendable {
    func pasteVirtualKeyCode() -> CGKeyCode
}

/// Last-resort insertion path for apps that accept synthetic Unicode input
/// but reject paste / AX value updates.
protocol TextTyping: Sendable {
    func typeText(_ text: String) throws
}

/// Pasteboard snapshot capture seam. Production wraps `PasteboardSnapshot.capture`;
/// tests fake it to drive the snapshot-throws → AX/typing fallback chain.
protocol PasteboardSnapshotting: Sendable {
    func capture(from pasteboard: NSPasteboard) throws -> PasteboardSnapshot
}

struct DefaultPasteboardSnapshotter: PasteboardSnapshotting {
    func capture(from pasteboard: NSPasteboard) throws -> PasteboardSnapshot {
        try PasteboardSnapshot.capture(from: pasteboard)
    }
}

/// Wraps `AXIsProcessTrusted()` so `inject()` can short-circuit with a
/// permissions-tagged error when Accessibility is revoked, rather than
/// running all three strategies and reporting three meaningless AX failures.
protocol AccessibilityTrustChecking: Sendable {
    func isAccessibilityTrusted() -> Bool
}

struct SystemAccessibilityTrust: AccessibilityTrustChecking {
    func isAccessibilityTrusted() -> Bool { AXIsProcessTrusted() }
}

/// Pre-flight check: does the current paste target look like it will honor
/// a Cmd+V keystroke? When false, ClipboardInjector skips the clipboard-paste
/// strategy entirely (without dirtying the clipboard) so the AX value-set
/// and synthetic-typing fallbacks can run instead.
protocol PasteEligibilityChecking: Sendable {
    func isPasteEligible() -> Bool
}

/// Default that always allows the paste path. Used in tests and as the
/// fallback for any caller that doesn't supply a stricter checker. The
/// production code path in `voxlineApp.swift` injects the AX-driven
/// `DefaultPasteEligibility` instead.
struct AlwaysPasteEligible: PasteEligibilityChecking {
    func isPasteEligible() -> Bool { true }
}

/// Production paste-eligibility checker. Considers two signals:
///   1. The frontmost app exposes an enabled Edit > Paste menu item with
///      Cmd+V as its key equivalent.
///   2. The focused AX element returns a non-nil text snapshot — i.e. the
///      element has a readable string value, which strongly correlates with
///      being a text-editing target that honors paste.
struct DefaultPasteEligibility: PasteEligibilityChecking {
    let focusedTextSystem: FocusedTextSystem

    func isPasteEligible() -> Bool {
        if AXMenuBarInspector.frontmostAppHasPasteMenuItem() { return true }
        if focusedTextSystem.snapshot() != nil { return true }
        return false
    }
}

/// Standalone AX menu-bar inspection used by `DefaultPasteEligibility`.
/// Lives outside the eligibility struct so it can be unit-tested if needed
/// and so the implementation reads top-to-bottom without recursion through
/// instance state.
enum AXMenuBarInspector {
    /// True iff the frontmost application's AX menu bar contains an enabled
    /// menu item whose `Cmd` equivalent is unmodified "V". Empty menu bars
    /// (no app frontmost, sandboxed agent apps that don't publish one) yield
    /// false.
    static func frontmostAppHasPasteMenuItem() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let menuBar = axElement(kAXMenuBarAttribute as CFString, on: appElement) else {
            return false
        }
        for menuBarItem in axChildren(of: menuBar) {
            for submenu in axChildren(of: menuBarItem) {
                for menuItem in axChildren(of: submenu) {
                    if isPasteMenuItem(menuItem) {
                        return axBool(kAXEnabledAttribute as CFString, on: menuItem) ?? true
                    }
                }
            }
        }
        return false
    }

    private static func isPasteMenuItem(_ element: AXUIElement) -> Bool {
        var cmdCharRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXMenuItemCmdChar" as CFString, &cmdCharRef) == .success,
              let cmdChar = cmdCharRef as? String,
              cmdChar.lowercased() == "v" else { return false }
        // AXMenuItemCmdModifiers: 0 means Command-only (no Shift/Option/Control).
        // Reject Cmd+Shift+V / Cmd+Option+V which are "Paste and Match Style"
        // and similar — they don't behave like a plain paste.
        var modRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXMenuItemCmdModifiers" as CFString, &modRef) == .success,
           let modifiers = modRef as? Int,
           modifiers != 0 {
            return false
        }
        return true
    }

    private static func axElement(_ attribute: CFString, on element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private static func axChildren(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let array = value as? [Any] else { return [] }
        return array.compactMap {
            let v = $0 as CFTypeRef
            guard CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
            return (v as! AXUIElement)
        }
    }

    private static func axBool(_ attribute: CFString, on element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value as? Bool
    }
}

struct FocusedTextSnapshot: Equatable, Sendable {
    let value: String
}

enum FocusedTextCheck: Equatable, Sendable {
    case confirmedChanged
    case unchanged
    case unavailable
}

/// Small AX wrapper used for paste verification and direct value insertion.
/// This intentionally exposes only string-like focused controls; rich editors
/// and custom views may report `.unavailable`, in which case the injector keeps
/// the old "best effort paste" behavior rather than risking a double insert.
protocol FocusedTextSystem: Sendable {
    func snapshot() -> FocusedTextSnapshot?
    func checkInsertion(before: FocusedTextSnapshot?, insertedText: String) -> FocusedTextCheck
    func insertText(_ text: String) throws
    /// True when the focused element is a secure text field (password input).
    /// `inject()` short-circuits in this case so dictated text never lands in
    /// a password store via paste, AX value-set, or synthetic typing.
    func focusedFieldIsSecure() -> Bool
}

enum TextInsertionStrategy: String, Equatable, Sendable {
    case clipboardPaste = "clipboard paste"
    case accessibility = "accessibility"
    case directTyping = "direct typing"
}

enum TextInsertionVerification: String, Equatable, Sendable {
    case confirmed = "confirmed"
    case unverified = "unverified"
}

struct TextInsertionOutcome: Equatable, Sendable, CustomStringConvertible {
    let strategy: TextInsertionStrategy
    let verification: TextInsertionVerification

    var description: String {
        "\(strategy.rawValue), \(verification.rawValue)"
    }
}

enum TextInsertionError: Error, LocalizedError, Equatable {
    case accessibilityNotGranted
    case clipboardSnapshotUnavailable(String)
    case clipboardPasteNotApplicable(String)
    case accessibilityUnavailable(String)
    case accessibilityRejected
    case directTypingUnavailable(String)
    case directTypingRejected
    case secureFieldUnsupported
    case allStrategiesFailed([String])

    var errorDescription: String? {
        switch self {
        case .accessibilityNotGranted:
            return "Voxline needs Accessibility permission to insert text. Grant access in System Settings → Privacy & Security → Accessibility."
        case .clipboardSnapshotUnavailable(let reason):
            return "Could not safely use the clipboard paste path: \(reason)."
        case .clipboardPasteNotApplicable(let reason):
            return "Clipboard paste skipped: \(reason)."
        case .accessibilityUnavailable(let reason):
            return "Accessibility insertion is unavailable: \(reason)."
        case .accessibilityRejected:
            return "The focused field did not appear to accept Accessibility insertion."
        case .directTypingUnavailable(let reason):
            return "Direct typing is unavailable: \(reason)."
        case .directTypingRejected:
            return "The focused field did not appear to accept direct typing."
        case .secureFieldUnsupported:
            return "The focused field is a secure text field. Voxline will not insert dictated text into password inputs."
        case .allStrategiesFailed(let failures):
            return "Text insertion failed. Tried clipboard paste, Accessibility insertion, and direct typing. \(failures.joined(separator: " "))"
        }
    }
}

struct CGEventModifierGate: ModifierGate {
    func chordIsHeld() -> Bool {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        // Flag bits for individual sides aren't exposed publicly on macOS;
        // checking the combined Control/Option masks is the documented way.
        // (This is conservative — any Ctrl or any Option held returns true.
        //  In practice voxline's chord IS Left-Ctrl + Left-Option so this is fine.)
        return flags.contains(.maskControl) || flags.contains(.maskAlternate)
    }

    func forceClearChord() {
        // .hidSystemState (vs .combinedSessionState) presents the event as
        // if it came from the keyboard hardware itself. Some apps — notably
        // TUI hosts running Claude Code-style autocomplete in Terminal /
        // iTerm — reliably honor HID-sourced modifier-clear events but
        // sometimes drop session-sourced ones.
        let src = CGEventSource(stateID: .hidSystemState)
        let event = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)
        event?.flags = []   // Clearing all modifier flags — a synthetic "fingers off keyboard"
        event?.type = .flagsChanged
        event?.post(tap: .cghidEventTap)
    }
}

struct CGEventKeyPoster: KeyEventPosting {
    func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags) {
        // .hidSystemState matches what a physical key press produces. Some
        // terminals with a mounted autocomplete suggestion swallow synthetic
        // Cmd+V posted from .combinedSessionState because they consult
        // CGEventSource.flagsState before processing the keystroke.
        let src = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true)
        down?.flags = flags
        down?.post(tap: .cghidEventTap)
        let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)
        up?.flags = flags
        up?.post(tap: .cghidEventTap)
    }
}

struct CurrentKeyboardLayoutPasteKeyResolver: PasteKeyResolving {
    private static let fallbackUSAnsiV: CGKeyCode = 9

    func pasteVirtualKeyCode() -> CGKeyCode {
        keyCode(forLowercaseCharacter: "v") ?? Self.fallbackUSAnsiV
    }

    private func keyCode(forLowercaseCharacter target: String) -> CGKeyCode? {
        guard
            let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            let layoutDataPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else {
            return nil
        }

        let layoutData = Unmanaged<CFData>.fromOpaque(layoutDataPointer).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(layoutData) else { return nil }
        let keyboardLayout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        let keyboardType = UInt32(LMGetKbdType())

        for keyCode in UInt16(0)..<UInt16(128) {
            var deadKeyState: UInt32 = 0
            var actualLength = 0
            var chars = [UniChar](repeating: 0, count: 8)
            let status = chars.withUnsafeMutableBufferPointer { buffer in
                UCKeyTranslate(
                    keyboardLayout,
                    keyCode,
                    UInt16(kUCKeyActionDisplay),
                    0,
                    keyboardType,
                    OptionBits(kUCKeyTranslateNoDeadKeysBit),
                    &deadKeyState,
                    buffer.count,
                    &actualLength,
                    buffer.baseAddress
                )
            }

            guard status == noErr, actualLength > 0 else { continue }
            let produced = String(utf16CodeUnits: chars, count: actualLength).lowercased()
            if produced == target {
                return CGKeyCode(keyCode)
            }
        }

        return nil
    }
}

struct CGEventTextTyper: TextTyping {
    func typeText(_ text: String) throws {
        guard !text.isEmpty else { return }
        let src = CGEventSource(stateID: .combinedSessionState)
        let units = Array(text.utf16)
        let chunkSize = 20

        var index = units.startIndex
        while index < units.endIndex {
            let end = units.index(index, offsetBy: chunkSize, limitedBy: units.endIndex) ?? units.endIndex
            var chunk = Array(units[index..<end])

            let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true)
            let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)
            guard let down, let up else {
                throw TextInsertionError.directTypingUnavailable("Could not create synthetic key events.")
            }
            chunk.withUnsafeMutableBufferPointer { buffer in
                down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
            }
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            index = end
        }
    }
}

struct AXFocusedTextSystem: FocusedTextSystem {
    func snapshot() -> FocusedTextSnapshot? {
        guard
            let element = focusedElement(),
            let value = stringValue(of: element)
        else {
            return nil
        }
        return FocusedTextSnapshot(value: value)
    }

    func checkInsertion(before: FocusedTextSnapshot?, insertedText: String) -> FocusedTextCheck {
        guard let before else { return .unavailable }
        guard let after = snapshot() else { return .unavailable }
        if after.value == before.value { return .unchanged }
        return .confirmedChanged
    }

    func focusedFieldIsSecure() -> Bool {
        guard let element = focusedElement() else { return false }
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &value)
        guard status == .success, let subrole = value as? String else { return false }
        return subrole == (kAXSecureTextFieldSubrole as String)
    }

    func insertText(_ text: String) throws {
        guard let element = focusedElement() else {
            throw TextInsertionError.accessibilityUnavailable("No focused editable element was exposed by macOS.")
        }

        if isAttributeSettable(kAXSelectedTextAttribute, on: element) {
            let status = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
            if status == .success { return }
        }

        guard isAttributeSettable(kAXValueAttribute, on: element) else {
            throw TextInsertionError.accessibilityUnavailable("The focused element does not allow its value to be changed.")
        }
        guard let value = stringValue(of: element) else {
            throw TextInsertionError.accessibilityUnavailable("The focused element does not expose a string value.")
        }

        let nsValue = value as NSString
        let selectedRange = selectedTextRange(of: element) ?? CFRange(location: nsValue.length, length: 0)
        guard selectedRange.location >= 0,
              selectedRange.length >= 0,
              selectedRange.location <= nsValue.length,
              selectedRange.location + selectedRange.length <= nsValue.length else {
            throw TextInsertionError.accessibilityUnavailable("The focused element exposes an invalid selection range.")
        }

        let updated = nsValue.replacingCharacters(
            in: NSRange(location: selectedRange.location, length: selectedRange.length),
            with: text
        )
        let status = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, updated as CFTypeRef)
        guard status == .success else {
            throw TextInsertionError.accessibilityUnavailable("macOS rejected the value update with AX status \(status.rawValue).")
        }

        var insertionPoint = CFRange(location: selectedRange.location + (text as NSString).length, length: 0)
        if let axRange = AXValueCreate(.cfRange, &insertionPoint) {
            _ = AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, axRange)
        }
    }

    private func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value)
        guard status == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private func stringValue(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
        guard status == .success else { return nil }
        return value as? String
    }

    private func selectedTextRange(of element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value)
        guard status == .success, let value, CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        let axValue = (value as! AXValue)
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return range
    }

    private func isAttributeSettable(_ attribute: String, on element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        let status = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
        return status == .success && settable.boolValue
    }
}

@MainActor
final class ClipboardInjector {

    typealias InjectError = TextInsertionError

    /// Virtual key code for "V" on macOS US ANSI layout.
    static let kVirtualKeyV: CGKeyCode = 9

    /// De-facto pasteboard hint types (nspasteboard.org) that well-behaved
    /// clipboard managers (Maccy, Paste, Pastebot, Alfred) honor by NOT
    /// archiving the entry into history. AutoGenerated says "this is a
    /// programmatic write, not user-copied"; Concealed says "this contains
    /// sensitive data" — relevant because the cleaned text may carry
    /// dictated passwords, 2FA codes, etc.
    private static let autoGeneratedType = NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType")
    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    let pasteboard: NSPasteboard
    let modifierGate: ModifierGate
    let keyPoster: KeyEventPosting
    let pasteKeyResolver: PasteKeyResolving
    let focusedTextSystem: FocusedTextSystem
    let textTyper: TextTyping
    let snapshotter: PasteboardSnapshotting
    let accessibilityTrust: AccessibilityTrustChecking
    let pasteEligibility: PasteEligibilityChecking
    let chordReleaseTimeout: Duration
    let chordPollInterval: Duration
    /// Sleep between writing the cleaned text to the pasteboard and posting
    /// the synthetic Cmd+V. Some apps (notably terminals hosting a TUI with
    /// an autocomplete suggestion mounted) drop the paste when the keystroke
    /// arrives too quickly after the clipboard write.
    let pasteWriteSettleDelay: Duration
    let restoreDelay: Duration
    let verificationDelay: Duration

    init(
        pasteboard: NSPasteboard = .general,
        modifierGate: ModifierGate = CGEventModifierGate(),
        keyPoster: KeyEventPosting = CGEventKeyPoster(),
        pasteKeyResolver: PasteKeyResolving = CurrentKeyboardLayoutPasteKeyResolver(),
        focusedTextSystem: FocusedTextSystem = AXFocusedTextSystem(),
        textTyper: TextTyping = CGEventTextTyper(),
        snapshotter: PasteboardSnapshotting = DefaultPasteboardSnapshotter(),
        accessibilityTrust: AccessibilityTrustChecking = SystemAccessibilityTrust(),
        pasteEligibility: PasteEligibilityChecking = AlwaysPasteEligible(),
        chordReleaseTimeout: Duration = .seconds(1),
        chordPollInterval: Duration = .milliseconds(15),
        pasteWriteSettleDelay: Duration = .milliseconds(50),
        restoreDelay: Duration = .milliseconds(300),
        verificationDelay: Duration = .milliseconds(150)
    ) {
        self.pasteboard = pasteboard
        self.modifierGate = modifierGate
        self.keyPoster = keyPoster
        self.pasteKeyResolver = pasteKeyResolver
        self.focusedTextSystem = focusedTextSystem
        self.textTyper = textTyper
        self.snapshotter = snapshotter
        self.accessibilityTrust = accessibilityTrust
        self.pasteEligibility = pasteEligibility
        self.chordReleaseTimeout = chordReleaseTimeout
        self.chordPollInterval = chordPollInterval
        self.pasteWriteSettleDelay = pasteWriteSettleDelay
        self.restoreDelay = restoreDelay
        self.verificationDelay = verificationDelay
    }

    /// Insert text into the focused field using progressively broader
    /// strategies:
    /// 1. Clipboard snapshot → write text → wait-for-release → Cmd+V → restore.
    /// 2. Accessibility focused-value insertion.
    /// 3. Synthetic Unicode typing.
    ///
    /// Fallbacks only run when a strategy fails *before* it can insert (snapshot
    /// refuse-to-clobber, AX rejects, etc.). A successfully-posted Cmd+V is
    /// treated as `.unverified` even when AX claims the focused value did not
    /// change — many opaque editors (Electron, WKWebView, custom NSTextView)
    /// expose a stale value through AX, and re-running AX/typing on top of a
    /// successful paste would double-insert.
    ///
    /// Secure (password) fields short-circuit before any strategy: dictated
    /// text must never reach a password store via paste, AX value-set, or
    /// synthetic typing.
    @discardableResult
    func inject(_ text: String) async throws -> TextInsertionOutcome {
        // Without Accessibility, every strategy degrades into something
        // user-hostile: paste posts Cmd+V via cghidEventTap (silently
        // no-ops), AX queries return nil, synthetic typing produces no
        // events. Bail with a sticky permissions error instead.
        guard accessibilityTrust.isAccessibilityTrusted() else {
            throw TextInsertionError.accessibilityNotGranted
        }

        if focusedTextSystem.focusedFieldIsSecure() {
            throw TextInsertionError.secureFieldUnsupported
        }

        var failures: [String] = []

        do {
            return try await injectViaClipboardPaste(text)
        } catch {
            AppLog.paste.debug("clipboard-paste failed: \(error.localizedDescription); trying AX value-set")
            failures.append(error.localizedDescription)
        }

        do {
            return try injectViaAccessibility(text)
        } catch {
            AppLog.paste.debug("AX value-set failed: \(error.localizedDescription); trying synthetic typing")
            failures.append(error.localizedDescription)
        }

        do {
            return try await injectViaDirectTyping(text)
        } catch {
            AppLog.paste.debug("synthetic typing failed: \(error.localizedDescription); all strategies exhausted")
            failures.append(error.localizedDescription)
        }

        throw TextInsertionError.allStrategiesFailed(failures)
    }

    private func injectViaClipboardPaste(_ text: String) async throws -> TextInsertionOutcome {
        // 0. Pre-flight eligibility. If the frontmost app has no enabled
        // Paste menu item and no readable focused field, posting a synthetic
        // Cmd+V will at best do nothing and at worst be eaten by the focused
        // app's keystroke handler. Bail BEFORE touching the clipboard so the
        // AX value-set / synthetic-typing fallbacks can run on a clean state.
        guard pasteEligibility.isPasteEligible() else {
            throw TextInsertionError.clipboardPasteNotApplicable("frontmost app does not expose a paste target")
        }

        let before = focusedTextSystem.snapshot()

        // 1. Snapshot. Throws on refuse-to-clobber; we propagate without
        // having touched the pasteboard.
        let snapshot: PasteboardSnapshot
        do {
            snapshot = try snapshotter.capture(from: pasteboard)
        } catch let e as PasteboardSnapshot.SnapshotError {
            throw TextInsertionError.clipboardSnapshotUnavailable(e.reason)
        } catch {
            throw TextInsertionError.clipboardSnapshotUnavailable(error.localizedDescription)
        }

        // From this point on, the cleaned text (potentially a password / 2FA
        // code spoken aloud) sits on NSPasteboard.general. Every exit path
        // — including thrown cancellation from waitForChordRelease and from
        // the post-paste Task.sleep — MUST restore the snapshot.
        do {
            // 2. Write cleaned text along with hint types so well-behaved
            // clipboard managers don't archive it into history.
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            pasteboard.setData(Data(), forType: Self.autoGeneratedType)
            pasteboard.setData(Data(), forType: Self.concealedType)

            // 3. Wait for the user's chord to release before posting Cmd+V.
            try await waitForChordRelease()

            // 3b. Small settle delay so the target app has time to observe
            // the clipboard write before the synthetic Cmd+V arrives. Without
            // this, TUIs in Terminal/iTerm with a mounted autocomplete
            // suggestion sometimes drop the paste — manual Cmd+V works
            // because of natural human-timing slack.
            try await Task.sleep(for: pasteWriteSettleDelay)

            // 4. Post Cmd+V with ONLY the Command flag.
            keyPoster.postKey(pasteKeyResolver.pasteVirtualKeyCode(), flags: [.maskCommand])

            // 5. Let the target app consume the paste, then verify.
            try await Task.sleep(for: restoreDelay)
            let check = focusedTextSystem.checkInsertion(before: before, insertedText: text)
            snapshot.restore(to: pasteboard)

            switch check {
            case .confirmedChanged:
                return TextInsertionOutcome(strategy: .clipboardPaste, verification: .confirmed)
            case .unavailable, .unchanged:
                // .unchanged here means "AX disagrees that anything changed."
                // That's not proof of failure — many editors expose stale
                // values via AX. Treat as unverified so we don't double-insert
                // on top of a paste that may well have succeeded.
                return TextInsertionOutcome(strategy: .clipboardPaste, verification: .unverified)
            }
        } catch {
            snapshot.restore(to: pasteboard)
            throw error
        }
    }

    private func injectViaAccessibility(_ text: String) throws -> TextInsertionOutcome {
        let before = focusedTextSystem.snapshot()
        try focusedTextSystem.insertText(text)
        switch focusedTextSystem.checkInsertion(before: before, insertedText: text) {
        case .confirmedChanged:
            return TextInsertionOutcome(strategy: .accessibility, verification: .confirmed)
        case .unavailable:
            return TextInsertionOutcome(strategy: .accessibility, verification: .unverified)
        case .unchanged:
            throw TextInsertionError.accessibilityRejected
        }
    }

    private func injectViaDirectTyping(_ text: String) async throws -> TextInsertionOutcome {
        let before = focusedTextSystem.snapshot()
        try await waitForChordRelease()
        try textTyper.typeText(text)
        try await Task.sleep(for: verificationDelay)
        switch focusedTextSystem.checkInsertion(before: before, insertedText: text) {
        case .confirmedChanged:
            return TextInsertionOutcome(strategy: .directTyping, verification: .confirmed)
        case .unavailable:
            return TextInsertionOutcome(strategy: .directTyping, verification: .unverified)
        case .unchanged:
            throw TextInsertionError.directTypingRejected
        }
    }

    private func waitForChordRelease() async throws {
        let deadline = ContinuousClock.now.advanced(by: chordReleaseTimeout)
        while modifierGate.chordIsHeld() {
            if ContinuousClock.now >= deadline {
                modifierGate.forceClearChord()
                return
            }
            try await Task.sleep(for: chordPollInterval)
        }
    }
}
