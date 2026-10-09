// voxline/Output/ClipboardInjector.swift
import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics

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
    /// Opaque identity of the currently focused element. Lets the paste
    /// verifier distinguish stale-AX (same element, unchanged value) from
    /// focus shift (different element after Cmd+V). Nil when unavailable.
    func focusedElementIdentity() -> AnyHashable?
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

struct AXFocusedTextSystem: FocusedTextSystem {
    func snapshot() -> FocusedTextSnapshot? {
        guard
            let element = AXUIElement.systemWideFocusedElement(),
            let value = element.stringAttribute(kAXValueAttribute)
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
        guard let element = AXUIElement.systemWideFocusedElement() else { return false }
        return element.stringAttribute(kAXSubroleAttribute) == (kAXSecureTextFieldSubrole as String)
    }

    func focusedElementIdentity() -> AnyHashable? {
        guard let element = AXUIElement.systemWideFocusedElement() else { return nil }
        return AnyHashable(AXElementIdentity(element: element))
    }

    func insertText(_ text: String) throws {
        guard let element = AXUIElement.systemWideFocusedElement() else {
            throw TextInsertionError.accessibilityUnavailable("No focused editable element was exposed by macOS.")
        }

        if isAttributeSettable(kAXSelectedTextAttribute, on: element) {
            let status = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
            if status == .success { return }
        }

        guard isAttributeSettable(kAXValueAttribute, on: element) else {
            throw TextInsertionError.accessibilityUnavailable("The focused element does not allow its value to be changed.")
        }
        guard let value = element.stringAttribute(kAXValueAttribute) else {
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

/// CFEqual/CFHash-backed identity wrapper so an AXUIElement can be
/// boxed in AnyHashable. CFType equality is by underlying UI element,
/// not by pointer value.
private struct AXElementIdentity: Hashable, @unchecked Sendable {
    let element: AXUIElement

    static func == (lhs: AXElementIdentity, rhs: AXElementIdentity) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(element))
    }
}

@MainActor
final class ClipboardInjector {

    typealias InjectError = TextInsertionError

    /// Virtual key code for "V" on macOS US ANSI layout.
    nonisolated static let kVirtualKeyV: CGKeyCode = 9

    /// Virtual key code for "C" on macOS US ANSI layout. Used by
    /// `SelectionSnapshot` to copy the current selection.
    nonisolated static let kVirtualKeyC: CGKeyCode = 8

    static let autoGeneratedType = PasteboardWriter.autoGeneratedType
    static let concealedType = PasteboardWriter.concealedType

    nonisolated static let defaultForceClearChord: @Sendable () -> Void = {
        let src = CGEventSource(stateID: .hidSystemState)
        let event = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)
        event?.flags = []
        event?.type = .flagsChanged
        event?.post(tap: .cghidEventTap)
    }

    nonisolated static let defaultPostKey: @Sendable (CGKeyCode, CGEventFlags) -> Void = { keyCode, flags in
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

    nonisolated static let defaultPasteVirtualKeyCode: @Sendable () -> CGKeyCode = {
        resolvePasteVirtualKey() ?? kVirtualKeyV
    }

    nonisolated static let defaultTypeText: @Sendable (String) throws -> Void = { text in
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

    nonisolated private static func resolvePasteVirtualKey() -> CGKeyCode? {
        let target = "v"
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

    let pasteboard: NSPasteboard
    let focusedTextSystem: FocusedTextSystem
    let snapshotter: PasteboardSnapshotting
    let chordIsHeld: @Sendable () -> Bool
    let forceClearChord: @Sendable () -> Void
    let postKey: @Sendable (CGKeyCode, CGEventFlags) -> Void
    let pasteVirtualKeyCode: @Sendable () -> CGKeyCode
    let typeText: @Sendable (String) throws -> Void
    let isAccessibilityTrusted: @Sendable () -> Bool
    let chordReleaseTimeout: Duration
    let chordPollInterval: Duration
    /// Sleep between writing the cleaned text to the pasteboard and posting
    /// the synthetic Cmd+V. Some apps (notably terminals hosting a TUI with
    /// an autocomplete suggestion mounted) drop the paste when the keystroke
    /// arrives too quickly after the clipboard write. The delay is
    /// known-necessary; removing it causes intermittent paste drops in
    /// affected terminals.
    let pasteWriteSettleDelay: Duration
    let restoreDelay: Duration
    let verificationDelay: Duration

    init(
        pasteboard: NSPasteboard = .general,
        focusedTextSystem: FocusedTextSystem = AXFocusedTextSystem(),
        snapshotter: PasteboardSnapshotting = DefaultPasteboardSnapshotter(),
        chordIsHeld: @escaping @Sendable () -> Bool = { false },
        forceClearChord: @escaping @Sendable () -> Void = ClipboardInjector.defaultForceClearChord,
        postKey: @escaping @Sendable (CGKeyCode, CGEventFlags) -> Void = ClipboardInjector.defaultPostKey,
        pasteVirtualKeyCode: @escaping @Sendable () -> CGKeyCode = ClipboardInjector.defaultPasteVirtualKeyCode,
        typeText: @escaping @Sendable (String) throws -> Void = ClipboardInjector.defaultTypeText,
        isAccessibilityTrusted: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() },
        chordReleaseTimeout: Duration = .seconds(1),
        chordPollInterval: Duration = .milliseconds(15),
        pasteWriteSettleDelay: Duration = .milliseconds(50),
        restoreDelay: Duration = .milliseconds(300),
        verificationDelay: Duration = .milliseconds(150)
    ) {
        self.pasteboard = pasteboard
        self.focusedTextSystem = focusedTextSystem
        self.snapshotter = snapshotter
        self.chordIsHeld = chordIsHeld
        self.forceClearChord = forceClearChord
        self.postKey = postKey
        self.pasteVirtualKeyCode = pasteVirtualKeyCode
        self.typeText = typeText
        self.isAccessibilityTrusted = isAccessibilityTrusted
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
        guard isAccessibilityTrusted() else {
            throw TextInsertionError.accessibilityNotGranted
        }

        if focusedTextSystem.focusedFieldIsSecure() {
            throw TextInsertionError.secureFieldUnsupported
        }

        var failures: [String] = []

        do {
            return try await injectViaClipboardPaste(text)
        } catch TextInsertionError.pasteVerificationFailed {
            // Focus shifted mid-paste; the cleaned text landed in an
            // unintended target. Fallback strategies would write into
            // the new focus, compounding the harm. Surface directly.
            AppLog.paste.error("paste verification failed: focused element changed mid-paste")
            throw TextInsertionError.pasteVerificationFailed
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
        let before = focusedTextSystem.snapshot()
        let beforeIdentity = focusedTextSystem.focusedElementIdentity()

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
        // code spoken aloud) sits on NSPasteboard.general. `defer` guarantees
        // restoration on every exit path — normal return, thrown error, or
        // parent-Task cancellation at any await.
        defer { snapshot.restore(to: pasteboard) }

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
        postKey(pasteVirtualKeyCode(), [.maskCommand])

        // 5. Let the target app consume the paste, then verify.
        try await Task.sleep(for: restoreDelay)
        let check = focusedTextSystem.checkInsertion(before: before, insertedText: text)

        switch check {
        case .confirmedChanged:
            return TextInsertionOutcome(strategy: .clipboardPaste, verification: .confirmed)
        case .unavailable:
            // Many opaque editors (Electron, WKWebView, custom NSTextView)
            // expose no usable AX value; the paste likely landed.
            return TextInsertionOutcome(strategy: .clipboardPaste, verification: .unverified)
        case .unchanged:
            // Same focused element → stale-AX quirk; paste probably landed.
            // Different focused element → focus shifted mid-paste; the
            // Cmd+V landed in an unintended target. Fallbacks would
            // compound the harm; surface a clear failure instead.
            let afterIdentity = focusedTextSystem.focusedElementIdentity()
            if let beforeIdentity, let afterIdentity, beforeIdentity != afterIdentity {
                throw TextInsertionError.pasteVerificationFailed
            }
            return TextInsertionOutcome(strategy: .clipboardPaste, verification: .unverified)
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
        try typeText(text)
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
        while chordIsHeld() {
            if ContinuousClock.now >= deadline {
                forceClearChord()
                return
            }
            try await Task.sleep(for: chordPollInterval)
        }
    }
}
