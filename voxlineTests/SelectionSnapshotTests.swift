import AppKit
import Testing
@testable import voxline

@Suite(.timeLimit(.minutes(1))) @MainActor struct SelectionSnapshotTests {

    private func makeBoard(_ text: String) -> NSPasteboard {
        let board = NSPasteboard(name: NSPasteboard.Name("voxline-test-\(UUID())"))
        board.clearContents()
        board.setString(text, forType: .string)
        return board
    }

    private func reader(_ board: NSPasteboard, timeout: Duration = .milliseconds(150),
                        postCopy: @escaping @Sendable @MainActor () -> Void) -> DefaultSelectionSnapshot {
        DefaultSelectionSnapshot(copyTimeout: timeout, pasteboardName: board.name, isTrusted: { true }, postCopy: postCopy)
    }

    nonisolated private static func copy(_ text: String, to name: NSPasteboard.Name) {
        let board = NSPasteboard(name: name)
        board.clearContents()
        board.setString(text, forType: .string)
    }

    @Test func an_unchanged_board_is_not_rewritten() async {
        let board = makeBoard("user clipboard")
        defer { board.releaseGlobally() }
        let before = board.changeCount
        let copies = LockedBox(0)

        let selection = await reader(board) { copies.mutate { $0 += 1 } }.readSelection()

        #expect(selection == nil)
        #expect(copies.read() == 1)
        #expect(board.changeCount == before)
        #expect(board.string(forType: .string) == "user clipboard")
    }

    @Test func returns_as_soon_as_the_copy_lands_and_restores_the_clipboard() async {
        let board = makeBoard("user clipboard")
        defer { board.releaseGlobally() }
        let name = board.name
        let start = ContinuousClock.now

        let selection = await reader(board, timeout: .seconds(20)) { Self.copy("selected text", to: name) }.readSelection()

        #expect(selection == "selected text")
        #expect(start.duration(to: .now) < .seconds(10))
        #expect(board.string(forType: .string) == "user clipboard")
    }

    @Test func a_copy_that_lands_late_is_still_read() async {
        let board = makeBoard("user clipboard")
        defer { board.releaseGlobally() }
        let name = board.name

        let selection = await reader(board, timeout: .seconds(20)) {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(50))
                Self.copy("selected text", to: name)
            }
        }.readSelection()

        #expect(selection == "selected text")
        #expect(board.string(forType: .string) == "user clipboard")
    }

    @Test func an_empty_copy_is_no_selection_and_is_restored() async {
        let board = makeBoard("user clipboard")
        defer { board.releaseGlobally() }
        let name = board.name

        let selection = await reader(board) { Self.copy("", to: name) }.readSelection()

        #expect(selection == nil)
        #expect(board.string(forType: .string) == "user clipboard")
    }

    @Test func a_cancelled_caller_still_waits_for_the_copy_before_restoring() async {
        let board = makeBoard("user clipboard")
        defer { board.releaseGlobally() }
        let name = board.name
        let posted = TestGate()
        let landed = TestGate()
        let hasLanded = LockedBox(false)
        let snapshot = reader(board, timeout: .seconds(20)) {
            posted.open()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(100))
                Self.copy("selected text", to: name)
                hasLanded.write(true)
                landed.open()
            }
        }

        let read = Task { await snapshot.readSelection() }
        await posted.wait()
        read.cancel()
        _ = await read.value

        #expect(hasLanded.read(), "the restore ran before the copy landed")
        await landed.wait()
        #expect(board.string(forType: .string) == "user clipboard")
    }

    @Test func untrusted_never_touches_the_clipboard() async {
        let board = makeBoard("user clipboard")
        defer { board.releaseGlobally() }
        let before = board.changeCount
        let copies = LockedBox(0)
        let snapshot = DefaultSelectionSnapshot(pasteboardName: board.name, isTrusted: { false }, postCopy: { copies.mutate { $0 += 1 } })

        #expect(await snapshot.readSelection() == nil)
        #expect(copies.read() == 0)
        #expect(board.changeCount == before)
    }
}
