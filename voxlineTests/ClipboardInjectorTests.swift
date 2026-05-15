// voxlineTests/ClipboardInjectorTests.swift
import Testing
import AppKit
@testable import voxline

/// Thread-safe box for capturing closure side-effects in tests.
final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ initial: T) { self.value = initial }
    func read() -> T { lock.lock(); defer { lock.unlock() }; return value }
    func write(_ new: T) { lock.lock(); value = new; lock.unlock() }
    func mutate(_ body: (inout T) -> Void) {
        lock.lock(); body(&value); lock.unlock()
    }
}

@Suite struct ClipboardInjectorTests {

    final class FakeFocusedTextSystem: FocusedTextSystem, @unchecked Sendable {
        var currentValue: String?
        var snapshotQueue: [FocusedTextSnapshot?] = []
        var inserted: [String] = []
        var insertError: Error?
        var isSecure = false

        func snapshot() -> FocusedTextSnapshot? {
            if !snapshotQueue.isEmpty {
                return snapshotQueue.removeFirst()
            }
            return currentValue.map { FocusedTextSnapshot(value: $0) }
        }

        func checkInsertion(before: FocusedTextSnapshot?, insertedText: String) -> FocusedTextCheck {
            guard let before else { return .unavailable }
            guard let after = snapshot() else { return .unavailable }
            return after.value == before.value ? .unchanged : .confirmedChanged
        }

        func focusedFieldIsSecure() -> Bool { isSecure }

        func insertText(_ text: String) throws {
            if let insertError { throw insertError }
            inserted.append(text)
            currentValue = (currentValue ?? "") + text
        }
    }

    /// Snapshotter that always throws — used to force the inject() fallback
    /// chain past the clipboard-paste strategy without depending on platform
    /// behavior of NSPasteboard.pasteboardItems.
    struct ThrowingSnapshotter: PasteboardSnapshotting {
        let reason: String
        func capture(from pasteboard: NSPasteboard) throws -> PasteboardSnapshot {
            throw PasteboardSnapshot.SnapshotError.refuseToClobber(reason: reason)
        }
    }

    private func makeBoard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name(rawValue: "voxline-inject-\(UUID().uuidString)"))
    }

    @Test func writes_text_then_posts_cmd_v_then_restores() async throws {
        let board = makeBoard()
        board.clearContents()
        board.setString("ORIGINAL", forType: .string)

        let focused = FakeFocusedTextSystem()
        let posted = LockedBox<[(code: CGKeyCode, flags: CGEventFlags)]>([])
        let injector = await ClipboardInjector(
            pasteboard: board,
            focusedTextSystem: focused,
            chordIsHeld: { false },
            forceClearChord: {},
            postKey: { code, flags in posted.mutate { $0.append((code, flags)) } },
            pasteVirtualKeyCode: { 9 },
            typeText: { _ in },
            isAccessibilityTrusted: { true },
            restoreDelay: .milliseconds(20)
        )

        let outcome = try await injector.inject("CLEAN")

        // After full inject + restoreDelay, original is back.
        #expect(board.string(forType: .string) == "ORIGINAL")
        // Cmd+V was posted exactly once with only Command flag.
        let snapshot = posted.read()
        #expect(snapshot.count == 1)
        #expect(snapshot[0].code == 9)             // 'V'
        #expect(snapshot[0].flags == [.maskCommand])
        #expect(outcome == TextInsertionOutcome(strategy: .clipboardPaste, verification: .unverified))
    }

    @Test func uses_layout_resolved_paste_key() async throws {
        let board = makeBoard()
        board.clearContents()
        board.setString("ORIGINAL", forType: .string)

        let posted = LockedBox<[CGKeyCode]>([])
        let injector = await ClipboardInjector(
            pasteboard: board,
            focusedTextSystem: FakeFocusedTextSystem(),
            chordIsHeld: { false },
            forceClearChord: {},
            postKey: { code, _ in posted.mutate { $0.append(code) } },
            pasteVirtualKeyCode: { 12 },
            typeText: { _ in },
            isAccessibilityTrusted: { true },
            restoreDelay: .milliseconds(0)
        )

        _ = try await injector.inject("CLEAN")

        #expect(posted.read() == [12])
    }

    @Test func waits_for_chord_release_before_posting() async throws {
        let board = makeBoard()
        board.clearContents()

        // Held twice, then released — should NOT clear, just wait.
        let chordSeq = LockedBox<[Bool]>([true, true, false])
        let callCount = LockedBox<Int>(0)
        let clearCount = LockedBox<Int>(0)
        let chordIsHeldClosure: @Sendable () -> Bool = {
            var result = false
            chordSeq.mutate { seq in
                if !seq.isEmpty { result = seq.removeFirst() }
            }
            callCount.mutate { $0 += 1 }
            return result
        }

        let posted = LockedBox<[(code: CGKeyCode, flags: CGEventFlags)]>([])
        let injector = await ClipboardInjector(
            pasteboard: board,
            focusedTextSystem: FakeFocusedTextSystem(),
            chordIsHeld: chordIsHeldClosure,
            forceClearChord: { clearCount.mutate { $0 += 1 } },
            postKey: { code, flags in posted.mutate { $0.append((code, flags)) } },
            pasteVirtualKeyCode: { 9 },
            typeText: { _ in },
            isAccessibilityTrusted: { true },
            restoreDelay: .milliseconds(0)
        )

        try await injector.inject("text")

        #expect(callCount.read() >= 3)        // polled until released
        #expect(clearCount.read() == 0)        // never had to force-clear
    }

    @Test func force_clears_chord_after_timeout() async throws {
        let board = makeBoard()
        board.clearContents()

        let clearCount = LockedBox<Int>(0)
        let posted = LockedBox<[(code: CGKeyCode, flags: CGEventFlags)]>([])
        let injector = await ClipboardInjector(
            pasteboard: board,
            focusedTextSystem: FakeFocusedTextSystem(),
            chordIsHeld: { true },
            forceClearChord: { clearCount.mutate { $0 += 1 } },
            postKey: { code, flags in posted.mutate { $0.append((code, flags)) } },
            pasteVirtualKeyCode: { 9 },
            typeText: { _ in },
            isAccessibilityTrusted: { true },
            chordReleaseTimeout: .milliseconds(20),
            chordPollInterval: .milliseconds(5),
            restoreDelay: .milliseconds(0)
        )

        try await injector.inject("t")

        #expect(clearCount.read() == 1)
        #expect(posted.read().count == 1)   // Cmd+V still fired after force-clear
    }

    @Test func paste_with_ax_unchanged_returns_unverified_and_does_not_double_insert() async throws {
        // AX reports the focused value didn't change after Cmd+V. That's
        // ambiguous — many editors expose stale AX values — so we must NOT
        // escalate to AX/typing on top of a paste that may have succeeded.
        let board = makeBoard()
        board.clearContents()
        board.setString("ORIGINAL", forType: .string)

        let focused = FakeFocusedTextSystem()
        focused.currentValue = "before"
        focused.snapshotQueue = [
            FocusedTextSnapshot(value: "before"),
            FocusedTextSnapshot(value: "before")
        ]
        let posted = LockedBox<[(code: CGKeyCode, flags: CGEventFlags)]>([])
        let typed = LockedBox<[String]>([])
        let injector = await ClipboardInjector(
            pasteboard: board,
            focusedTextSystem: focused,
            chordIsHeld: { false },
            forceClearChord: {},
            postKey: { code, flags in posted.mutate { $0.append((code, flags)) } },
            pasteVirtualKeyCode: { 9 },
            typeText: { text in typed.mutate { $0.append(text) } },
            isAccessibilityTrusted: { true },
            restoreDelay: .milliseconds(0)
        )

        let outcome = try await injector.inject("CLEAN")

        #expect(posted.read().count == 1)
        #expect(focused.inserted.isEmpty)
        #expect(typed.read().isEmpty)
        #expect(outcome == TextInsertionOutcome(strategy: .clipboardPaste, verification: .unverified))
        #expect(board.string(forType: .string) == "ORIGINAL")
    }

    @Test func snapshot_failure_falls_through_to_accessibility() async throws {
        let board = makeBoard()
        board.clearContents()
        board.setString("ORIGINAL", forType: .string)

        let focused = FakeFocusedTextSystem()
        focused.currentValue = "before"
        let posted = LockedBox<[(code: CGKeyCode, flags: CGEventFlags)]>([])
        let injector = await ClipboardInjector(
            pasteboard: board,
            focusedTextSystem: focused,
            snapshotter: ThrowingSnapshotter(reason: "test forced failure"),
            chordIsHeld: { false },
            forceClearChord: {},
            postKey: { code, flags in posted.mutate { $0.append((code, flags)) } },
            pasteVirtualKeyCode: { 9 },
            typeText: { _ in },
            isAccessibilityTrusted: { true },
            restoreDelay: .milliseconds(0)
        )

        let outcome = try await injector.inject("CLEAN")

        #expect(focused.inserted == ["CLEAN"])
        #expect(outcome == TextInsertionOutcome(strategy: .accessibility, verification: .confirmed))
        // Paste path bailed before touching the clipboard.
        #expect(posted.read().isEmpty)
        #expect(board.string(forType: .string) == "ORIGINAL")
    }

    @Test func accessibility_rejection_falls_back_to_direct_typing() async throws {
        struct NoAX: Error {}
        let board = makeBoard()
        board.clearContents()
        board.setString("ORIGINAL", forType: .string)

        let focused = FakeFocusedTextSystem()
        focused.currentValue = "before"
        focused.insertError = NoAX()

        let typed = LockedBox<[String]>([])
        let injector = await ClipboardInjector(
            pasteboard: board,
            focusedTextSystem: focused,
            snapshotter: ThrowingSnapshotter(reason: "test forced failure"),
            chordIsHeld: { false },
            forceClearChord: {},
            postKey: { _, _ in },
            pasteVirtualKeyCode: { 9 },
            typeText: { text in
                typed.mutate { $0.append(text) }
                focused.currentValue = (focused.currentValue ?? "") + text
            },
            isAccessibilityTrusted: { true },
            restoreDelay: .milliseconds(0),
            verificationDelay: .milliseconds(0)
        )

        let outcome = try await injector.inject("CLEAN")

        #expect(focused.inserted.isEmpty)
        #expect(typed.read() == ["CLEAN"])
        #expect(outcome == TextInsertionOutcome(strategy: .directTyping, verification: .confirmed))
    }

    /// Privacy invariant: if anything throws after we've written the cleaned
    /// text to NSPasteboard, the original clipboard contents must come back.
    /// This guards against dictated passwords / 2FA codes lingering on the
    /// system clipboard when the user cancels mid-dictation.
    @Test func paste_path_restores_clipboard_when_chord_release_is_cancelled() async throws {
        let board = makeBoard()
        board.clearContents()
        board.setString("ORIGINAL", forType: .string)

        let injector = await ClipboardInjector(
            pasteboard: board,
            focusedTextSystem: FakeFocusedTextSystem(),
            chordIsHeld: { true },
            forceClearChord: {},
            postKey: { _, _ in },
            pasteVirtualKeyCode: { 9 },
            typeText: { _ in },
            isAccessibilityTrusted: { true },
            chordReleaseTimeout: .seconds(60),   // long enough that we cancel first
            chordPollInterval: .milliseconds(5),
            restoreDelay: .milliseconds(0),
            verificationDelay: .milliseconds(0)
        )

        let task = Task { try await injector.inject("SECRET") }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        _ = try? await task.value

        // Original clipboard contents are back; the dictated SECRET is gone.
        #expect(board.string(forType: .string) == "ORIGINAL")
    }

    @Test func revoked_accessibility_short_circuits_with_permissions_error() async throws {
        let board = makeBoard()
        board.clearContents()
        board.setString("ORIGINAL", forType: .string)

        let focused = FakeFocusedTextSystem()
        focused.currentValue = "before"
        let posted = LockedBox<[(code: CGKeyCode, flags: CGEventFlags)]>([])
        let typed = LockedBox<[String]>([])
        let injector = await ClipboardInjector(
            pasteboard: board,
            focusedTextSystem: focused,
            chordIsHeld: { false },
            forceClearChord: {},
            postKey: { code, flags in posted.mutate { $0.append((code, flags)) } },
            pasteVirtualKeyCode: { 9 },
            typeText: { text in typed.mutate { $0.append(text) } },
            isAccessibilityTrusted: { false },
            restoreDelay: .milliseconds(0)
        )

        await #expect(throws: TextInsertionError.accessibilityNotGranted) {
            _ = try await injector.inject("CLEAN")
        }

        // Trust check must run before any strategy. None should have side-effected.
        #expect(board.string(forType: .string) == "ORIGINAL")
        #expect(posted.read().isEmpty)
        #expect(focused.inserted.isEmpty)
        #expect(typed.read().isEmpty)
    }

    @Test func secure_field_short_circuits_without_writing_clipboard_or_typing() async throws {
        let board = makeBoard()
        board.clearContents()
        board.setString("ORIGINAL", forType: .string)

        let focused = FakeFocusedTextSystem()
        focused.currentValue = "before"
        focused.isSecure = true

        let posted = LockedBox<[(code: CGKeyCode, flags: CGEventFlags)]>([])
        let typed = LockedBox<[String]>([])
        let injector = await ClipboardInjector(
            pasteboard: board,
            focusedTextSystem: focused,
            chordIsHeld: { false },
            forceClearChord: {},
            postKey: { code, flags in posted.mutate { $0.append((code, flags)) } },
            pasteVirtualKeyCode: { 9 },
            typeText: { text in typed.mutate { $0.append(text) } },
            isAccessibilityTrusted: { true },
            restoreDelay: .milliseconds(0)
        )

        await #expect(throws: TextInsertionError.secureFieldUnsupported) {
            _ = try await injector.inject("PASSWORD")
        }

        // None of the three strategies ran.
        #expect(board.string(forType: .string) == "ORIGINAL")
        #expect(posted.read().isEmpty)
        #expect(focused.inserted.isEmpty)
        #expect(typed.read().isEmpty)
    }

    @Test func chord_held_predicate_uses_chord_specific_device_bits() {
        let chord = HotkeyChord(modifierA: .rightCommand, modifierB: .rightShift)

        let rightCmdFlags = CGEventFlags(rawValue: HotkeyChord.Modifier.rightCommand.deviceMaskBit)
        let controlOnly  = CGEventFlags(rawValue: HotkeyChord.Modifier.leftControl.deviceMaskBit)
        let none         = CGEventFlags(rawValue: 0)

        let predicateWhenRightCmd = ClipboardInjector.chordIsHeld(in: rightCmdFlags, chord: chord)
        let predicateWhenCtrlOnly = ClipboardInjector.chordIsHeld(in: controlOnly, chord: chord)
        let predicateWhenEmpty    = ClipboardInjector.chordIsHeld(in: none, chord: chord)

        #expect(predicateWhenRightCmd == true)
        #expect(predicateWhenCtrlOnly == false)
        #expect(predicateWhenEmpty == false)
    }
}
