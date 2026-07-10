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

    /// Records synthetic key posts and simulates a well-behaved editor's
    /// Cmd+C: writing the current "selection" onto the pasteboard. `@unchecked
    /// Sendable` because `postKey` is a `@Sendable` closure; all access is from
    /// the test's MainActor.
    final class KeyRecorder: @unchecked Sendable {
        let board: NSPasteboard
        /// What a Cmd+C copies onto the board — i.e. what the keystroke
        /// selection actually grabbed. Nil simulates a copy that puts nothing
        /// new on the board (e.g. no selection).
        let copyText: String?
        var keys: [(CGKeyCode, CGEventFlags)] = []

        init(board: NSPasteboard, copyText: String?) {
            self.board = board
            self.copyText = copyText
        }

        func post(_ keyCode: CGKeyCode, _ flags: CGEventFlags) {
            keys.append((keyCode, flags))
            if keyCode == ClipboardInjector.kVirtualKeyC, flags.contains(.maskCommand),
               let copyText {
                board.clearContents()
                board.setString(copyText, forType: .string)
            }
        }

        var shiftLefts: Int {
            keys.filter { $0.0 == ClipboardInjector.kVirtualKeyLeftArrow && $0.1.contains(.maskShift) }.count
        }
    }

    private func makeBoard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name(rawValue: "voxline-replace-\(UUID().uuidString)"))
    }

    @MainActor
    private func makeKeystrokeInjector(board: NSPasteboard, focused: Focused, recorder: KeyRecorder) -> ClipboardInjector {
        ClipboardInjector(
            pasteboard: board,
            focusedTextSystem: focused,
            chordIsHeld: { false },
            postKey: { recorder.post($0, $1) },
            typeText: { _ in },
            isAccessibilityTrusted: { true },
            pasteWriteSettleDelay: .zero,
            restoreDelay: .zero,
            verificationDelay: .zero
        )
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

    // MARK: - Keystroke-selection fallback (AX-hostile editors, e.g. Obsidian)

    @Test @MainActor func axSelectionUnavailable_keystrokeSelectsVerifiesAndReplaces() async {
        let board = makeBoard(); board.clearContents(); board.setString("USER-CLIP", forType: .string)
        let focused = Focused(); focused.selectResult = .some(nil) // AX selected-range unavailable
        let recorder = KeyRecorder(board: board, copyText: "old text") // Cmd+C grabs exactly the prior insertion
        let injector = makeKeystrokeInjector(board: board, focused: focused, recorder: recorder)

        let outcome = await injector.replace("old text", with: "new text")

        if case .replaced = outcome {} else { Issue.record("expected .replaced, got \(outcome)") }
        // One Shift+Left per grapheme of the prior insertion.
        #expect(recorder.shiftLefts == "old text".count)
        // The user's clipboard is restored after the swap.
        #expect(board.string(forType: .string) == "USER-CLIP")
    }

    @Test @MainActor func keystrokeSelectionMismatch_fallsBackAndRestoresClipboard() async {
        let board = makeBoard(); board.clearContents(); board.setString("USER-CLIP", forType: .string)
        let focused = Focused(); focused.selectResult = .some(nil)
        // Cmd+C grabs something other than the prior insertion (caret moved / user typed).
        let recorder = KeyRecorder(board: board, copyText: "unexpected selection")
        let injector = makeKeystrokeInjector(board: board, focused: focused, recorder: recorder)

        let outcome = await injector.replace("old text", with: "new text")

        #expect(outcome == .fallbackClipboard)
        // Mismatch must NOT overwrite: new text is left on the clipboard for manual paste.
        #expect(board.string(forType: .string) == "new text")
        // On mismatch we deselect (Right arrow) rather than paste over the selection.
        #expect(recorder.keys.contains { $0.0 == ClipboardInjector.kVirtualKeyRightArrow })
    }

    @Test @MainActor func keystrokeCopyDoesNothing_fallsBack() async {
        let board = makeBoard(); board.clearContents(); board.setString("USER-CLIP", forType: .string)
        let focused = Focused(); focused.selectResult = .some(nil)
        // Cmd+C changes nothing (no selection was made). Must not treat the
        // user's stale clipboard as a verified selection.
        let recorder = KeyRecorder(board: board, copyText: nil)
        let injector = makeKeystrokeInjector(board: board, focused: focused, recorder: recorder)

        let outcome = await injector.replace("USER-CLIP", with: "new text")

        #expect(outcome == .fallbackClipboard)
        #expect(board.string(forType: .string) == "new text")
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
