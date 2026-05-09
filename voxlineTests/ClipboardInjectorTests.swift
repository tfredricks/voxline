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

    private func makeBoard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name(rawValue: "voxline-inject-\(UUID().uuidString)"))
    }

    @Test func writes_text_then_posts_cmd_v_then_restores() async throws {
        let board = makeBoard()
        board.clearContents()
        board.setString("ORIGINAL", forType: .string)

        let gate = FakeModifierGate()
        let poster = FakeKeyPoster()
        let injector = await ClipboardInjector(
            pasteboard: board,
            modifierGate: gate,
            keyPoster: poster,
            restoreDelay: .milliseconds(20)   // short for tests
        )

        try await injector.inject("CLEAN")

        // After full inject + restoreDelay, original is back.
        #expect(board.string(forType: .string) == "ORIGINAL")
        // Cmd+V was posted exactly once with only Command flag.
        #expect(poster.posted.count == 1)
        #expect(poster.posted[0].keyCode == 9)               // 'V'
        #expect(poster.posted[0].flags == [.maskCommand])
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

    @Test func refuse_to_clobber_throws_without_writing_or_pasting() async throws {
        // Force a refuse-to-clobber scenario by giving the injector a board
        // whose pasteboardItems is nil. (Skip if the platform returns [].)
        let board = NSPasteboard(name: NSPasteboard.Name(rawValue: "voxline-empty-\(UUID().uuidString)"))
        guard board.pasteboardItems == nil else { return }

        let poster = FakeKeyPoster()
        let injector = await ClipboardInjector(
            pasteboard: board,
            modifierGate: FakeModifierGate(),
            keyPoster: poster,
            restoreDelay: .milliseconds(0)
        )

        do {
            try await injector.inject("anything")
            Issue.record("expected refuse-to-clobber error")
        } catch is ClipboardInjector.InjectError {
            // ok
        } catch is PasteboardSnapshot.SnapshotError {
            // ok — propagated
        }
        #expect(poster.posted.isEmpty)
    }
}
