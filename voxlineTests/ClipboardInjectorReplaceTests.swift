import Testing
import AppKit
@testable import voxline

@Suite struct ClipboardInjectorReplaceTests {

    // Reuse the same focused-text fake shape as ClipboardInjectorTests.
    final class Focused: FocusedTextSystem, @unchecked Sendable {
        var isSecure = false
        var identity: AnyHashable? = "el"
        var identityQueue: [AnyHashable?] = []
        var selectResult: String??       // inner nil = AX failure
        var selectCalls: [Int] = []
        func snapshot() -> FocusedTextSnapshot? { nil }
        func checkInsertion(before: FocusedTextSnapshot?, insertedText: String) -> FocusedTextCheck { .unavailable }
        func focusedFieldIsSecure() -> Bool { isSecure }
        func insertText(_ text: String) throws {}
        func focusedElementIdentity() -> AnyHashable? {
            if !identityQueue.isEmpty { return identityQueue.removeFirst() }
            return identity
        }
        func selectTextEndingAtCaret(utf16Length: Int) -> String? {
            selectCalls.append(utf16Length)
            if case let .some(v) = selectResult { return v }
            return nil
        }
    }

    private func makeBoard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name(rawValue: "voxline-replace-\(UUID().uuidString)"))
    }

    @MainActor
    private func makeInjector(board: NSPasteboard, focused: Focused, accessibility: Bool = true) -> ClipboardInjector {
        ClipboardInjector(
            pasteboard: board,
            focusedTextSystem: focused,
            chordIsHeld: { false },
            postKey: { _, _ in },
            typeText: { _ in },
            isAccessibilityTrusted: { accessibility },
            restoreDelay: .zero,
            verificationDelay: .zero
        )
    }

    @Test @MainActor func exactMatch_replacesInPlace() async {
        let board = makeBoard(); board.clearContents(); board.setString("USER-CLIP", forType: .string)
        let focused = Focused(); focused.selectResult = .some("old text")
        let injector = makeInjector(board: board, focused: focused)

        let outcome = await injector.replace("old text", with: "new text")

        if case .replaced = outcome {} else { Issue.record("expected .replaced, got \(outcome)") }
        #expect(focused.selectCalls == ["old text".utf16.count])
    }

    @Test @MainActor func selectionMismatch_fallsBackToClipboard() async {
        let board = makeBoard()
        let focused = Focused(); focused.selectResult = .some("something else")
        let injector = makeInjector(board: board, focused: focused)

        let outcome = await injector.replace("old text", with: "new text")

        #expect(outcome == .fallbackClipboard)
        #expect(board.string(forType: .string) == "new text")
    }

    @Test @MainActor func selectionAXFailure_fallsBackToClipboard() async {
        let board = makeBoard()
        let focused = Focused(); focused.selectResult = .some(nil) // AX could not set/read range
        let injector = makeInjector(board: board, focused: focused)

        let outcome = await injector.replace("old", with: "new")

        #expect(outcome == .fallbackClipboard)
        #expect(board.string(forType: .string) == "new")
    }

    @Test @MainActor func secureField_fallsBackWithoutSelecting() async {
        let board = makeBoard()
        let focused = Focused(); focused.isSecure = true; focused.selectResult = .some("old")
        let injector = makeInjector(board: board, focused: focused)

        let outcome = await injector.replace("old", with: "new")

        #expect(outcome == .fallbackClipboard)
        #expect(focused.selectCalls.isEmpty)
        #expect(board.string(forType: .string) == "new")
    }

    @Test @MainActor func focusMovedDuringSelect_fallsBack() async {
        let board = makeBoard()
        let focused = Focused()
        focused.selectResult = .some("old")
        // identity read before select == "el"; read after select == "other"
        focused.identityQueue = ["el", "other"]
        let injector = makeInjector(board: board, focused: focused)

        let outcome = await injector.replace("old", with: "new")

        #expect(outcome == .fallbackClipboard)
        #expect(board.string(forType: .string) == "new")
    }

    @Test @MainActor func noAccessibility_fallsBack() async {
        let board = makeBoard()
        let focused = Focused(); focused.selectResult = .some("old")
        let injector = makeInjector(board: board, focused: focused, accessibility: false)

        let outcome = await injector.replace("old", with: "new")

        #expect(outcome == .fallbackClipboard)
        #expect(focused.selectCalls.isEmpty)
    }
}
