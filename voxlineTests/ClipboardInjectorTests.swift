// voxlineTests/ClipboardInjectorTests.swift
import Testing
import AppKit
@testable import voxline

@Suite struct ClipboardInjectorTests {

    final class FakeModifierGate: ModifierGate, @unchecked Sendable {
        var sequence: [Bool] = [false]   // Each call pops the front; default = released
        var calls = 0
        var clearAttempts = 0
        func chordIsHeld() -> Bool {
            calls += 1
            return sequence.isEmpty ? false : sequence.removeFirst()
        }
        func forceClearChord() { clearAttempts += 1 }
    }

    final class FakeKeyPoster: KeyEventPosting, @unchecked Sendable {
        var posted: [(keyCode: CGKeyCode, flags: CGEventFlags)] = []
        func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags) {
            posted.append((keyCode, flags))
        }
    }

    struct FakePasteKeyResolver: PasteKeyResolving {
        let keyCode: CGKeyCode
        func pasteVirtualKeyCode() -> CGKeyCode { keyCode }
    }

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

    struct StubAccessibilityTrust: AccessibilityTrustChecking {
        let trusted: Bool
        func isAccessibilityTrusted() -> Bool { trusted }
    }

    final class FakeTextTyper: TextTyping, @unchecked Sendable {
        var typed: [String] = []
        var error: Error?
        var onType: ((String) -> Void)?

        func typeText(_ text: String) throws {
            if let error { throw error }
            typed.append(text)
            onType?(text)
        }
    }

    private func makeBoard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name(rawValue: "voxline-inject-\(UUID().uuidString)"))
    }

    @Test func writes_text_then_posts_cmd_v_then_restores() async throws {
        let board = makeBoard()
        board.clearContents()
        board.setString("ORIGINAL", forType: .string)

        let gate = FakeModifierGate()
        let poster = FakeKeyPoster()
        let focused = FakeFocusedTextSystem()
        let injector = await ClipboardInjector(
            pasteboard: board,
            modifierGate: gate,
            keyPoster: poster,
            pasteKeyResolver: FakePasteKeyResolver(keyCode: 9),
            focusedTextSystem: focused,
            textTyper: FakeTextTyper(),
            accessibilityTrust: StubAccessibilityTrust(trusted: true),
            restoreDelay: .milliseconds(20)   // short for tests
        )

        let outcome = try await injector.inject("CLEAN")

        // After full inject + restoreDelay, original is back.
        #expect(board.string(forType: .string) == "ORIGINAL")
        // Cmd+V was posted exactly once with only Command flag.
        #expect(poster.posted.count == 1)
        #expect(poster.posted[0].keyCode == 9)               // 'V'
        #expect(poster.posted[0].flags == [.maskCommand])
        #expect(outcome == TextInsertionOutcome(strategy: .clipboardPaste, verification: .unverified))
    }

    @Test func uses_layout_resolved_paste_key() async throws {
        let board = makeBoard()
        board.clearContents()
        board.setString("ORIGINAL", forType: .string)

        let poster = FakeKeyPoster()
        let injector = await ClipboardInjector(
            pasteboard: board,
            modifierGate: FakeModifierGate(),
            keyPoster: poster,
            pasteKeyResolver: FakePasteKeyResolver(keyCode: 12),
            focusedTextSystem: FakeFocusedTextSystem(),
            textTyper: FakeTextTyper(),
            accessibilityTrust: StubAccessibilityTrust(trusted: true),
            restoreDelay: .milliseconds(0)
        )

        _ = try await injector.inject("CLEAN")

        #expect(poster.posted.map(\.keyCode) == [12])
    }

    @Test func waits_for_chord_release_before_posting() async throws {
        let board = makeBoard()
        board.clearContents()

        let gate = FakeModifierGate()
        // Held twice, then released — should NOT clear, just wait.
        gate.sequence = [true, true, false]

        let poster = FakeKeyPoster()
        let injector = await ClipboardInjector(
            pasteboard: board,
            modifierGate: gate,
            keyPoster: poster,
            pasteKeyResolver: FakePasteKeyResolver(keyCode: 9),
            focusedTextSystem: FakeFocusedTextSystem(),
            textTyper: FakeTextTyper(),
            accessibilityTrust: StubAccessibilityTrust(trusted: true),
            restoreDelay: .milliseconds(0)
        )

        try await injector.inject("text")

        #expect(gate.calls >= 3)        // polled until released
        #expect(gate.clearAttempts == 0) // never had to force-clear
    }

    @Test func force_clears_chord_after_timeout() async throws {
        let board = makeBoard()
        board.clearContents()
        let poster = FakeKeyPoster()
        let alwaysHeld = AlwaysHeldGate()
        let injector = await ClipboardInjector(
            pasteboard: board,
            modifierGate: alwaysHeld,
            keyPoster: poster,
            pasteKeyResolver: FakePasteKeyResolver(keyCode: 9),
            focusedTextSystem: FakeFocusedTextSystem(),
            textTyper: FakeTextTyper(),
            accessibilityTrust: StubAccessibilityTrust(trusted: true),
            chordReleaseTimeout: .milliseconds(20),
            chordPollInterval: .milliseconds(5),
            restoreDelay: .milliseconds(0)
        )

        try await injector.inject("t")

        #expect(alwaysHeld.clearAttempts == 1)
        #expect(poster.posted.count == 1)   // Cmd+V still fired after force-clear
    }

    final class AlwaysHeldGate: ModifierGate, @unchecked Sendable {
        var clearAttempts = 0
        func chordIsHeld() -> Bool { true }
        func forceClearChord() { clearAttempts += 1 }
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
        let poster = FakeKeyPoster()
        let typer = FakeTextTyper()
        let injector = await ClipboardInjector(
            pasteboard: board,
            modifierGate: FakeModifierGate(),
            keyPoster: poster,
            pasteKeyResolver: FakePasteKeyResolver(keyCode: 9),
            focusedTextSystem: focused,
            textTyper: typer,
            accessibilityTrust: StubAccessibilityTrust(trusted: true),
            restoreDelay: .milliseconds(0)
        )

        let outcome = try await injector.inject("CLEAN")

        #expect(poster.posted.count == 1)
        #expect(focused.inserted.isEmpty)
        #expect(typer.typed.isEmpty)
        #expect(outcome == TextInsertionOutcome(strategy: .clipboardPaste, verification: .unverified))
        #expect(board.string(forType: .string) == "ORIGINAL")
    }

    @Test func snapshot_failure_falls_through_to_accessibility() async throws {
        let board = makeBoard()
        board.clearContents()
        board.setString("ORIGINAL", forType: .string)

        let focused = FakeFocusedTextSystem()
        focused.currentValue = "before"
        let poster = FakeKeyPoster()
        let injector = await ClipboardInjector(
            pasteboard: board,
            modifierGate: FakeModifierGate(),
            keyPoster: poster,
            pasteKeyResolver: FakePasteKeyResolver(keyCode: 9),
            focusedTextSystem: focused,
            textTyper: FakeTextTyper(),
            snapshotter: ThrowingSnapshotter(reason: "test forced failure"),
            accessibilityTrust: StubAccessibilityTrust(trusted: true),
            restoreDelay: .milliseconds(0)
        )

        let outcome = try await injector.inject("CLEAN")

        #expect(focused.inserted == ["CLEAN"])
        #expect(outcome == TextInsertionOutcome(strategy: .accessibility, verification: .confirmed))
        // Paste path bailed before touching the clipboard.
        #expect(poster.posted.isEmpty)
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

        let typer = FakeTextTyper()
        typer.onType = { text in focused.currentValue = (focused.currentValue ?? "") + text }

        let injector = await ClipboardInjector(
            pasteboard: board,
            modifierGate: FakeModifierGate(),
            keyPoster: FakeKeyPoster(),
            pasteKeyResolver: FakePasteKeyResolver(keyCode: 9),
            focusedTextSystem: focused,
            textTyper: typer,
            snapshotter: ThrowingSnapshotter(reason: "test forced failure"),
            accessibilityTrust: StubAccessibilityTrust(trusted: true),
            restoreDelay: .milliseconds(0),
            verificationDelay: .milliseconds(0)
        )

        let outcome = try await injector.inject("CLEAN")

        #expect(focused.inserted.isEmpty)
        #expect(typer.typed == ["CLEAN"])
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
            modifierGate: AlwaysHeldGate(),
            keyPoster: FakeKeyPoster(),
            pasteKeyResolver: FakePasteKeyResolver(keyCode: 9),
            focusedTextSystem: FakeFocusedTextSystem(),
            textTyper: FakeTextTyper(),
            accessibilityTrust: StubAccessibilityTrust(trusted: true),
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
        let poster = FakeKeyPoster()
        let typer = FakeTextTyper()
        let injector = await ClipboardInjector(
            pasteboard: board,
            modifierGate: FakeModifierGate(),
            keyPoster: poster,
            pasteKeyResolver: FakePasteKeyResolver(keyCode: 9),
            focusedTextSystem: focused,
            textTyper: typer,
            accessibilityTrust: StubAccessibilityTrust(trusted: false),
            restoreDelay: .milliseconds(0)
        )

        await #expect(throws: TextInsertionError.accessibilityNotGranted) {
            _ = try await injector.inject("CLEAN")
        }

        // Trust check must run before any strategy. None should have side-effected.
        #expect(board.string(forType: .string) == "ORIGINAL")
        #expect(poster.posted.isEmpty)
        #expect(focused.inserted.isEmpty)
        #expect(typer.typed.isEmpty)
    }

    @Test func secure_field_short_circuits_without_writing_clipboard_or_typing() async throws {
        let board = makeBoard()
        board.clearContents()
        board.setString("ORIGINAL", forType: .string)

        let focused = FakeFocusedTextSystem()
        focused.currentValue = "before"
        focused.isSecure = true

        let poster = FakeKeyPoster()
        let typer = FakeTextTyper()
        let injector = await ClipboardInjector(
            pasteboard: board,
            modifierGate: FakeModifierGate(),
            keyPoster: poster,
            pasteKeyResolver: FakePasteKeyResolver(keyCode: 9),
            focusedTextSystem: focused,
            textTyper: typer,
            accessibilityTrust: StubAccessibilityTrust(trusted: true),
            restoreDelay: .milliseconds(0)
        )

        await #expect(throws: TextInsertionError.secureFieldUnsupported) {
            _ = try await injector.inject("PASSWORD")
        }

        // None of the three strategies ran.
        #expect(board.string(forType: .string) == "ORIGINAL")
        #expect(poster.posted.isEmpty)
        #expect(focused.inserted.isEmpty)
        #expect(typer.typed.isEmpty)
    }
}
