# Post-dictation Pill Refine Actions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** After a successful dictation the recording pill lingers ~7s with three one-click refinements — **Terser · Longer · Clearer** — each re-running LLM cleanup over the original transcript and replacing the just-pasted text in place.

**Architecture:** A new `ReviewSession` value on `AppState` (parallel to `toastMessage`) holds the transcript, mode, context, and the exact string sitting in the target field; it drives the pill's visibility and interactivity while `AppStatus` is untouched. `CapturePipeline` creates the session after a successful paste, owns its expiry timer, and gains `refine(_:)` which re-runs `LLMServing.cleanup` with a `RefinementDirective` and swaps the result in via a new verified `ClipboardInjecting.replace(_:with:)`. Replace degrades to leaving the new text on the clipboard when an in-place swap can't be verified.

**Tech Stack:** Swift 6 (strict concurrency, `@MainActor`), AppKit/SwiftUI/AVFoundation, Swift Testing (`@Test` / `#expect` / `@Suite` — NOT XCTest), Xcode project `voxline.xcodeproj`, scheme `voxline`.

## Global Constraints

- macOS 14.0+ deployment target; Apple Silicon only.
- Swift 6 strict concurrency. `AppState`, `CapturePipeline`, `ClipboardInjector`, `RecordingPillWindow` are `@MainActor`. `LLMServing`, `FocusedTextSystem`, `ReplaceOutcome`, `RefinementDirective` are `Sendable`.
- Tests use Swift Testing (`import Testing`, `@Suite`, `@Test`, `#expect`, `Issue.record`). Never XCTest.
- Test command: `xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS'` — add `-only-testing:voxlineTests/<SuiteName>` for one suite. Do NOT pipe through `xcbeautify` (or `set -o pipefail` first if you do).
- Commit style: conventional commits (`feat:`, `fix:`, `test:`) matching `git log`; commit directly on `main` (repo owner's workflow); end every commit message with the trailer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Directive prompt strings (verbatim, from the spec):
  - terser — `Rewrite to be significantly more concise while preserving the full meaning.`
  - longer — `Expand into fuller, more complete sentences; keep the meaning, add no new claims.`
  - clearer — `Rewrite for clarity, grammar, and flow — fix awkward phrasing without changing the meaning or register.`
- Linger window: `reviewLingerDuration = 7` seconds. Toast auto-dismiss: 2 seconds (matches the existing HistoryView pattern of a self-cancelling `Task.sleep`).
- The pill panel is `.nonactivatingPanel`; nothing in the refine path may activate voxline or deactivate the frontmost app — focus must stay in the field that was pasted into, or both the AX replace and the ⌘V fallback target the wrong app.

---

### Task 1: `ReviewSession` value type + `AppState.reviewSession`

**Files:**
- Create: `voxline/Pipeline/ReviewSession.swift`
- Modify: `voxline/AppState.swift` (add one property after `lastCleanupDuration`, currently line 86)
- Test: `voxlineTests/AppStateTests.swift`

**Interfaces:**
- Consumes: `Mode` (Equatable), `CapturedContext` (Equatable).
- Produces: `struct ReviewSession: Equatable, Sendable` with `let transcript: String`, `let mode: Mode`, `let context: CapturedContext`, `var insertedText: String`, `var expiresAt: Date`; and `AppState.reviewSession: ReviewSession?` (default `nil`).

- [ ] **Step 1: Write the failing test**

Add to `voxlineTests/AppStateTests.swift` (inside the existing `@Suite @MainActor struct AppStateTests`):

```swift
@Test func reviewSession_defaultsToNil_andRoundTrips() {
    let state = AppState()
    #expect(state.reviewSession == nil)

    let mode = Mode(bundleID: "*", displayName: "d", prompt: "p", model: nil, temperature: nil)
    let session = ReviewSession(
        transcript: "raw words",
        mode: mode,
        context: .empty,
        insertedText: "Cleaned words.",
        expiresAt: Date(timeIntervalSince1970: 1000)
    )
    state.reviewSession = session
    #expect(state.reviewSession == session)
    #expect(state.reviewSession?.insertedText == "Cleaned words.")
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/AppStateTests`
Expected: FAIL to build — `ReviewSession` and `reviewSession` are undefined.

- [ ] **Step 3: Create `ReviewSession`**

Create `voxline/Pipeline/ReviewSession.swift`:

```swift
import Foundation

/// The short-lived "you just dictated — want to tweak it?" window. Created by
/// `CapturePipeline` after a successful paste and cleared on expiry, dismissal,
/// or the next chord press. Holds the *original transcript* (not the cleaned
/// output) so refinements re-run from everything the user actually said, plus
/// the exact string currently sitting in the target field so a refine can
/// replace precisely that text.
///
/// Clearing the session is also the memory scrub: the transcript copy dies with
/// it, bounding how long spoken secrets linger in process memory (~7s idle,
/// reset on interaction) rather than "until the next dictation".
struct ReviewSession: Equatable, Sendable {
    let transcript: String
    let mode: Mode
    let context: CapturedContext
    var insertedText: String
    var expiresAt: Date
}
```

- [ ] **Step 4: Add the property to `AppState`**

In `voxline/AppState.swift`, after the `lastCleanupDuration` property (currently ending line 86), before the closing `}` of the class, add:

```swift

    /// Non-nil while a just-completed dictation is offering quick refinements
    /// (Terser / Longer / Clearer). Drives `RecordingPillWindow`'s visibility
    /// and interactivity, exactly like `toastMessage` drives the toast pill.
    /// Owned and expired by `CapturePipeline`; the view only reads it.
    var reviewSession: ReviewSession?
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/AppStateTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add voxline/Pipeline/ReviewSession.swift voxline/AppState.swift voxlineTests/AppStateTests.swift
git commit -m "feat: add ReviewSession state for post-dictation refinement

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: `RefinementDirective` + thread a refinement through the LLM

**Files:**
- Create: `voxline/LLM/RefinementDirective.swift`
- Modify: `voxline/Pipeline/PipelineProtocols.swift:36-38` (`LLMServing.cleanup` signature)
- Modify: `voxline/LLM/LLMService.swift` (extract `systemPrompt`, pass through refinement)
- Modify: `voxline/Pipeline/CapturePipeline.swift:157` (pass `refinement: nil`)
- Modify: `voxlineTests/CapturePipelineTests.swift:31-38` (`FakeLLM`)
- Modify: `voxlineTests/CapturePipelineErrorTaxonomyTests.swift:162-168` (`FakeLLM`)
- Test: `voxlineTests/LLMServiceTests.swift`

**Interfaces:**
- Consumes: `Mode`, `LLMService.transcriptionPreamble`.
- Produces: `enum RefinementDirective: String, CaseIterable, Sendable, Equatable { case terser, longer, clearer }` with `var promptText: String`; revised requirement `LLMServing.cleanup(transcript:mode:context:refinement:)`; static `LLMService.systemPrompt(mode:refinement:) -> String`.

- [ ] **Step 1: Write the failing tests**

Add a new file `voxlineTests/RefinementDirectiveTests.swift`:

```swift
import Testing
@testable import voxline

@Suite struct RefinementDirectiveTests {
    @Test func promptText_isStablePerDirective() {
        #expect(RefinementDirective.terser.promptText ==
            "Rewrite to be significantly more concise while preserving the full meaning.")
        #expect(RefinementDirective.longer.promptText ==
            "Expand into fuller, more complete sentences; keep the meaning, add no new claims.")
        #expect(RefinementDirective.clearer.promptText ==
            "Rewrite for clarity, grammar, and flow — fix awkward phrasing without changing the meaning or register.")
    }

    @Test func allCases_areTheThreeDirectives() {
        #expect(RefinementDirective.allCases == [.terser, .longer, .clearer])
    }
}
```

Add to `voxlineTests/LLMServiceTests.swift` (inside `@Suite struct LLMServiceTests`):

```swift
@Test func systemPrompt_withoutRefinement_isPreambleAndModePrompt() {
    let mode = Mode(bundleID: "*", displayName: "d", prompt: "MODE_STYLE", model: nil, temperature: nil)
    let prompt = LLMService.systemPrompt(mode: mode, refinement: nil)
    #expect(prompt == LLMService.transcriptionPreamble + "\n" + "MODE_STYLE")
}

@Test func systemPrompt_withRefinement_appendsDirectiveOnce() {
    let mode = Mode(bundleID: "*", displayName: "d", prompt: "MODE_STYLE", model: nil, temperature: nil)
    let prompt = LLMService.systemPrompt(mode: mode, refinement: .terser)
    let expected = LLMService.transcriptionPreamble + "\n" + "MODE_STYLE"
        + "\n\nThe user asked for this specific adjustment to the rewrite: "
        + RefinementDirective.terser.promptText
    #expect(prompt == expected)
    // Directive text must appear exactly once.
    #expect(prompt.components(separatedBy: RefinementDirective.terser.promptText).count == 2)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/RefinementDirectiveTests -only-testing:voxlineTests/LLMServiceTests`
Expected: FAIL to build — `RefinementDirective` and `LLMService.systemPrompt` are undefined.

- [ ] **Step 3: Create `RefinementDirective`**

Create `voxline/LLM/RefinementDirective.swift`:

```swift
/// A one-click adjustment the user can apply to a just-completed dictation.
/// The `promptText` is appended to the mode's system prompt for a refine pass;
/// see `LLMService.systemPrompt(mode:refinement:)`.
enum RefinementDirective: String, CaseIterable, Sendable, Equatable {
    case terser
    case longer
    case clearer

    var promptText: String {
        switch self {
        case .terser:
            return "Rewrite to be significantly more concise while preserving the full meaning."
        case .longer:
            return "Expand into fuller, more complete sentences; keep the meaning, add no new claims."
        case .clearer:
            return "Rewrite for clarity, grammar, and flow — fix awkward phrasing without changing the meaning or register."
        }
    }
}
```

- [ ] **Step 4: Revise the `LLMServing` protocol requirement**

In `voxline/Pipeline/PipelineProtocols.swift`, replace lines 36-38:

```swift
protocol LLMServing: Sendable {
    func cleanup(transcript: String, mode: Mode, context: CapturedContext) async throws -> String
}
```

with:

```swift
protocol LLMServing: Sendable {
    /// - Parameter refinement: nil for a normal first-pass cleanup (prompt is
    ///   byte-identical to before this parameter existed); a directive for a
    ///   post-dictation refine pass.
    func cleanup(transcript: String, mode: Mode, context: CapturedContext, refinement: RefinementDirective?) async throws -> String
}
```

- [ ] **Step 5: Extract `systemPrompt` and thread refinement in `LLMService`**

In `voxline/LLM/LLMService.swift`, add this static method immediately after the `transcriptionPreamble` declaration closes (after line 61's `"""`):

```swift

    /// Assemble the system prompt: fixed preamble + the mode's style guidance,
    /// plus an optional one-off refinement directive for a refine pass. Pure
    /// function so prompt assembly is unit-testable without an HTTP round-trip.
    static func systemPrompt(mode: Mode, refinement: RefinementDirective?) -> String {
        let base = transcriptionPreamble + "\n" + mode.prompt
        guard let refinement else { return base }
        return base + "\n\nThe user asked for this specific adjustment to the rewrite: " + refinement.promptText
    }
```

Change the `cleanup` signature (line 73) from:

```swift
    func cleanup(transcript: String, mode: Mode, context: CapturedContext) async throws -> String {
```

to:

```swift
    func cleanup(transcript: String, mode: Mode, context: CapturedContext, refinement: RefinementDirective?) async throws -> String {
```

And change the `LLMRequest` construction (lines 94-99) so `systemPrompt` uses the new helper:

```swift
        let request = LLMRequest(
            model: model,
            systemPrompt: Self.systemPrompt(mode: mode, refinement: refinement),
            userPrompt: userPrompt,
            temperature: mode.temperature
        )
```

- [ ] **Step 6: Update the production call site**

In `voxline/Pipeline/CapturePipeline.swift`, line 157, change:

```swift
            cleaned = try await llm.cleanup(transcript: transcript, mode: mode, context: context)
```

to:

```swift
            cleaned = try await llm.cleanup(transcript: transcript, mode: mode, context: context, refinement: nil)
```

- [ ] **Step 7: Update the two test `FakeLLM`s**

In `voxlineTests/CapturePipelineTests.swift`, replace the `FakeLLM` class (lines 31-38) with:

```swift
    final class FakeLLM: LLMServing, @unchecked Sendable {
        var nextResult: Result<String, Error> = .success("cleaned")
        var calls: [(transcript: String, mode: Mode, context: CapturedContext, refinement: RefinementDirective?)] = []
        func cleanup(transcript: String, mode: Mode, context: CapturedContext, refinement: RefinementDirective?) async throws -> String {
            calls.append((transcript, mode, context, refinement))
            return try nextResult.get()
        }
    }
```

In `voxlineTests/CapturePipelineErrorTaxonomyTests.swift`, replace the `FakeLLM` class (lines 162-168) with:

```swift
private final class FakeLLM: LLMServing, @unchecked Sendable {
    let handler: (String, Mode, CapturedContext) async throws -> String
    init(handler: @escaping (String, Mode, CapturedContext) async throws -> String) { self.handler = handler }
    func cleanup(transcript: String, mode: Mode, context: CapturedContext, refinement: RefinementDirective?) async throws -> String {
        try await handler(transcript, mode, context)
    }
}
```

- [ ] **Step 8: Run the tests to verify they pass**

Run: `xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/RefinementDirectiveTests -only-testing:voxlineTests/LLMServiceTests -only-testing:voxlineTests/CapturePipelineTests -only-testing:voxlineTests/CapturePipelineErrorTaxonomyTests`
Expected: PASS (all four suites build and pass).

- [ ] **Step 9: Commit**

```bash
git add voxline/LLM/RefinementDirective.swift voxline/LLM/LLMService.swift voxline/Pipeline/PipelineProtocols.swift voxline/Pipeline/CapturePipeline.swift voxlineTests/RefinementDirectiveTests.swift voxlineTests/LLMServiceTests.swift voxlineTests/CapturePipelineTests.swift voxlineTests/CapturePipelineErrorTaxonomyTests.swift
git commit -m "feat: thread RefinementDirective through LLM cleanup

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Verified in-place `replace` on the injector

**Files:**
- Create: `voxline/Output/ReplaceOutcome.swift`
- Modify: `voxline/Pipeline/PipelineProtocols.swift:40-44` (`ClipboardInjecting`)
- Modify: `voxline/Output/ClipboardInjector.swift` (`FocusedTextSystem` protocol + `AXFocusedTextSystem` impl + `ClipboardInjector.replace`)
- Modify: `voxlineTests/ClipboardInjectorTests.swift:20-56` (`FakeFocusedTextSystem`)
- Modify: `voxlineTests/CapturePipelineTests.swift:50-58` (`FakeInjector`)
- Modify: `voxlineTests/CapturePipelineErrorTaxonomyTests.swift:178-183` (`FakeInjector`)
- Test: `voxlineTests/ClipboardInjectorTests.swift`

**Interfaces:**
- Consumes: existing `injectViaClipboardPaste(_:)`, `focusedTextSystem`, `isAccessibilityTrusted`, `pasteboard`.
- Produces: `enum ReplaceOutcome: Equatable, Sendable { case replaced(TextInsertionOutcome); case fallbackClipboard }`; `FocusedTextSystem.selectTextEndingAtCaret(utf16Length:) -> String?`; `ClipboardInjecting.replace(_:with:) async -> ReplaceOutcome`.

- [ ] **Step 1: Write the failing tests**

First extend the test fake so it can model selection. In `voxlineTests/ClipboardInjectorTests.swift`, add these members to `FakeFocusedTextSystem` (inside the class, after `focusedElementIdentity()` at line 55):

```swift
        // Selection modeling for replace() tests.
        var selectReturns: String??      // outer nil = not stubbed; inner nil = failure
        var selectCalls: [Int] = []
        func selectTextEndingAtCaret(utf16Length: Int) -> String? {
            selectCalls.append(utf16Length)
            if case let .some(value) = selectReturns { return value }
            return nil
        }
```

Then add a new suite `voxlineTests/ClipboardInjectorReplaceTests.swift`:

```swift
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/ClipboardInjectorReplaceTests`
Expected: FAIL to build — `ReplaceOutcome`, `replace`, and `selectTextEndingAtCaret` are undefined.

- [ ] **Step 3: Create `ReplaceOutcome`**

Create `voxline/Output/ReplaceOutcome.swift`:

```swift
/// Result of an in-place replace. `.replaced` means the prior insertion was
/// selected and pasted over (the user's clipboard was snapshotted and
/// restored). `.fallbackClipboard` means an in-place swap couldn't be verified,
/// so the new text was left on the clipboard for a manual ⌘V.
enum ReplaceOutcome: Equatable, Sendable {
    case replaced(TextInsertionOutcome)
    case fallbackClipboard
}
```

- [ ] **Step 4: Add `selectTextEndingAtCaret` to the `FocusedTextSystem` protocol**

In `voxline/Output/ClipboardInjector.swift`, add to the `FocusedTextSystem` protocol (after `insertText(_:)` at line 122, before the closing `}` at line 131 — pick a spot alongside the other requirements):

```swift
    /// Select `utf16Length` UTF-16 code units ending at the current caret and
    /// return the text now covered by that selection — or nil if the range
    /// can't be set or read back. `replace()` uses this to confirm it's about
    /// to overwrite exactly the expected text before pasting over it.
    func selectTextEndingAtCaret(utf16Length: Int) -> String?
```

- [ ] **Step 5: Implement it in `AXFocusedTextSystem`**

In `voxline/Output/ClipboardInjector.swift`, add to `struct AXFocusedTextSystem` (after `insertText(_:)` closes at line 258, before the private `selectedTextRange` helper at line 260):

```swift
    func selectTextEndingAtCaret(utf16Length: Int) -> String? {
        guard utf16Length >= 0,
              let element = AXUIElement.systemWideFocusedElement(),
              let caret = selectedTextRange(of: element) else { return nil }
        let end = caret.location + caret.length
        let start = end - utf16Length
        guard start >= 0 else { return nil }
        var range = CFRange(location: start, length: utf16Length)
        guard let axRange = AXValueCreate(.cfRange, &range),
              AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, axRange) == .success else {
            return nil
        }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success,
              let selected = value as? String else { return nil }
        return selected
    }
```

- [ ] **Step 6: Add `replace` to the `ClipboardInjecting` protocol**

In `voxline/Pipeline/PipelineProtocols.swift`, replace lines 40-44:

```swift
@MainActor
protocol ClipboardInjecting: AnyObject {
    @discardableResult
    func inject(_ text: String) async throws -> TextInsertionOutcome
}
```

with:

```swift
@MainActor
protocol ClipboardInjecting: AnyObject {
    @discardableResult
    func inject(_ text: String) async throws -> TextInsertionOutcome
    /// Replace an exact prior insertion in place. Degrades to leaving `new` on
    /// the clipboard (returning `.fallbackClipboard`) when the swap can't be
    /// verified — never throws, never mangles the field.
    func replace(_ old: String, with new: String) async -> ReplaceOutcome
}
```

- [ ] **Step 7: Implement `replace` in `ClipboardInjector`**

In `voxline/Output/ClipboardInjector.swift`, add this method to `ClipboardInjector` immediately after `inject(_:)` closes (after line 534):

```swift
    /// Replace an exact prior insertion in place: select the `old` text ending
    /// at the caret, confirm it's exactly `old`, then paste `new` over the
    /// selection with the normal clipboard-paste machinery (which snapshots and
    /// restores the user's clipboard). Any doubt — no AX, secure field, range
    /// can't be read, text doesn't match, focus moved, paste fails — degrades
    /// to leaving `new` on the clipboard for a manual ⌘V.
    func replace(_ old: String, with new: String) async -> ReplaceOutcome {
        func fallback() -> ReplaceOutcome {
            pasteboard.clearContents()
            pasteboard.setString(new, forType: .string)
            return .fallbackClipboard
        }

        guard isAccessibilityTrusted(), !focusedTextSystem.focusedFieldIsSecure() else {
            return fallback()
        }

        let beforeIdentity = focusedTextSystem.focusedElementIdentity()
        guard let selected = focusedTextSystem.selectTextEndingAtCaret(utf16Length: old.utf16.count),
              selected == old,
              focusedTextSystem.focusedElementIdentity() == beforeIdentity else {
            return fallback()
        }

        do {
            let outcome = try await injectViaClipboardPaste(new)
            return .replaced(outcome)
        } catch {
            AppLog.paste.debug("replace paste failed: \(error.localizedDescription); leaving text on clipboard")
            return fallback()
        }
    }
```

- [ ] **Step 8: Update the two test `FakeInjector`s**

In `voxlineTests/CapturePipelineTests.swift`, replace the `FakeInjector` class (lines 50-58) with:

```swift
    final class FakeInjector: ClipboardInjecting {
        var injected: [String] = []
        var nextError: Error?
        var replaceCalls: [(old: String, new: String)] = []
        var replaceOutcome: ReplaceOutcome = .replaced(TextInsertionOutcome(strategy: .clipboardPaste, verification: .confirmed))
        func inject(_ text: String) async throws -> TextInsertionOutcome {
            if let nextError { throw nextError }
            injected.append(text)
            return TextInsertionOutcome(strategy: .clipboardPaste, verification: .unverified)
        }
        func replace(_ old: String, with new: String) async -> ReplaceOutcome {
            replaceCalls.append((old, new))
            return replaceOutcome
        }
    }
```

In `voxlineTests/CapturePipelineErrorTaxonomyTests.swift`, add a `replace` method to `FakeInjector` (inside the class at lines 178-183, after `inject`):

```swift
    func replace(_ old: String, with new: String) async -> ReplaceOutcome { .fallbackClipboard }
```

- [ ] **Step 9: Run the tests to verify they pass**

Run: `xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/ClipboardInjectorReplaceTests -only-testing:voxlineTests/ClipboardInjectorTests -only-testing:voxlineTests/CapturePipelineTests -only-testing:voxlineTests/CapturePipelineErrorTaxonomyTests`
Expected: PASS.

- [ ] **Step 10: Commit**

```bash
git add voxline/Output/ReplaceOutcome.swift voxline/Output/ClipboardInjector.swift voxline/Pipeline/PipelineProtocols.swift voxlineTests/ClipboardInjectorReplaceTests.swift voxlineTests/ClipboardInjectorTests.swift voxlineTests/CapturePipelineTests.swift voxlineTests/CapturePipelineErrorTaxonomyTests.swift
git commit -m "feat: add verified in-place replace to ClipboardInjector

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: `DictationHistoryStore.updateMostRecent`

**Files:**
- Modify: `voxline/Storage/DictationHistoryStore.swift` (add one method after `record`)
- Test: `voxlineTests/DictationHistoryStoreTests.swift`

**Interfaces:**
- Consumes: existing `items`, `persist()`, `DictationHistoryItem`, `String.isBlank`.
- Produces: `DictationHistoryStore.updateMostRecent(cleanedText: String)`.

- [ ] **Step 1: Write the failing tests**

Add to `voxlineTests/DictationHistoryStoreTests.swift` (inside the existing suite; it is `@MainActor` because the store is):

```swift
@Test func updateMostRecent_replacesNewestText_preservingIdentity() {
    let store = DictationHistoryStore(defaults: freshDefaults())
    let mode = Mode(bundleID: "*", displayName: "d", prompt: "p", model: nil, temperature: nil, category: .general)
    store.record(cleanedText: "first version", mode: mode, context: .empty)
    let id = store.items.first!.id
    let ts = store.items.first!.timestamp

    store.updateMostRecent(cleanedText: "refined version")

    #expect(store.items.count == 1)
    #expect(store.items.first?.cleanedText == "refined version")
    #expect(store.items.first?.id == id)          // same row, not a new one
    #expect(store.items.first?.timestamp == ts)
}

@Test func updateMostRecent_ignoresBlank_andEmptyHistory() {
    let store = DictationHistoryStore(defaults: freshDefaults())
    store.updateMostRecent(cleanedText: "nothing to update")   // empty history: no-op
    #expect(store.items.isEmpty)

    let mode = Mode(bundleID: "*", displayName: "d", prompt: "p", model: nil, temperature: nil, category: .general)
    store.record(cleanedText: "keep me", mode: mode, context: .empty)
    store.updateMostRecent(cleanedText: "   ")                 // blank: no-op
    #expect(store.items.first?.cleanedText == "keep me")
}
```

If a `freshDefaults()` helper doesn't already exist in this file, add it inside the suite:

```swift
private func freshDefaults() -> UserDefaults {
    let name = "voxline-test-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
}
```

(If the file already has an equivalent helper, reuse it and skip adding a duplicate.)

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/DictationHistoryStoreTests`
Expected: FAIL to build — `updateMostRecent` is undefined.

- [ ] **Step 3: Implement `updateMostRecent`**

In `voxline/Storage/DictationHistoryStore.swift`, add after the `record` method (after line 61):

```swift

    /// Replace the text of the newest entry — the one `record` just added for
    /// the current dictation — when a refine pass produces a better version.
    /// Keeps the same id/timestamp/app/mode so chained refines don't spam
    /// history. Blank text or empty history is a no-op (the refine flow only
    /// calls this right after a successful `record`, so the empty case is
    /// purely defensive).
    func updateMostRecent(cleanedText: String) {
        guard !cleanedText.isBlank, let current = items.first else { return }
        items[0] = DictationHistoryItem(
            id: current.id,
            timestamp: current.timestamp,
            cleanedText: cleanedText,
            modeCategoryName: current.modeCategoryName,
            appName: current.appName,
            appBundleID: current.appBundleID
        )
        persist()
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/DictationHistoryStoreTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add voxline/Storage/DictationHistoryStore.swift voxlineTests/DictationHistoryStoreTests.swift
git commit -m "feat: add updateMostRecent to DictationHistoryStore

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: `CapturePipeline` — session lifecycle + `refine(_:)`

**Files:**
- Modify: `voxline/Pipeline/CapturePipeline.swift` (init params, session helpers, `startRecording`, `finalizeRecording`, new `refine`)
- Test: `voxlineTests/CapturePipelineTests.swift`

**Interfaces:**
- Consumes: `ReviewSession`, `RefinementDirective`, `ReplaceOutcome`, `LLMServing.cleanup(…refinement:)`, `ClipboardInjecting.replace(_:with:)`, `DictationHistoryStore.updateMostRecent`.
- Produces (all `@MainActor` on `CapturePipeline`): init params `reviewLingerDuration: TimeInterval = 7` and `now: @escaping @Sendable () -> Date = { Date() }`; methods `refine(_ directive: RefinementDirective) async`, `expireReview()`, `dismissReview()`, `pauseReviewExpiry()`, `resumeReviewExpiry()`.

- [ ] **Step 1: Write the failing tests**

Add to `voxlineTests/CapturePipelineTests.swift` (inside the suite). These build the pipeline directly with a fixed clock rather than via `makePipeline`, so `expiresAt` is deterministic:

```swift
    private func makeRefinePipeline(
        now: Date = Date(timeIntervalSince1970: 10_000),
        linger: TimeInterval = 7
    ) -> (CapturePipeline, AppState, FakeLLM, FakeInjector, DictationHistoryStore) {
        let state = AppState()
        let capture = FakeCapture()
        let transcriber = FakeTranscriber()
        let llm = FakeLLM()
        let front = FakeFrontmost(); front.bundleID = "com.tinyspeck.slackmacgap"
        let inspector = FakeFieldInspector()
        let injector = FakeInjector()
        let router = ModeRouter(modes: [
            Mode(bundleID: "com.tinyspeck.slackmacgap", displayName: "Slack", prompt: "slack-prompt", model: nil, temperature: nil, category: .chat),
            Mode(bundleID: "*", displayName: "Default", prompt: "default-prompt", model: nil, temperature: nil, category: .general)
        ])
        let name = "voxline-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let history = DictationHistoryStore(defaults: defaults)
        let pipe = CapturePipeline(
            state: state, capture: capture, transcriber: transcriber,
            llm: llm, modes: router, frontmost: front,
            fieldInspector: inspector, injector: injector,
            historyStore: history, contextCapture: FakeContextCapture(),
            reviewLingerDuration: linger, now: { now }
        )
        return (pipe, state, llm, injector, history)
    }

    @Test func finalize_success_opensReviewSessionWithExpiry() async {
        let now = Date(timeIntervalSince1970: 10_000)
        let (pipe, state, _, _, _) = makeRefinePipeline(now: now, linger: 7)
        pipe.startRecording()
        state.lastPeakLevel = 0.5
        await pipe.finalizeRecording()

        let session = state.reviewSession
        #expect(session != nil)
        #expect(session?.transcript == "hello world")   // FakeTranscriber default
        #expect(session?.insertedText == "cleaned")      // FakeLLM default
        #expect(session?.expiresAt == now.addingTimeInterval(7))
    }

    @Test func startRecording_clearsAnyReviewSession() async {
        let (pipe, state, _, _, _) = makeRefinePipeline()
        pipe.startRecording(); state.lastPeakLevel = 0.5; await pipe.finalizeRecording()
        #expect(state.reviewSession != nil)
        pipe.startRecording()
        #expect(state.reviewSession == nil)
    }

    @Test func expireReview_scrubsSession() async {
        let (pipe, state, _, _, _) = makeRefinePipeline()
        pipe.startRecording(); state.lastPeakLevel = 0.5; await pipe.finalizeRecording()
        pipe.expireReview()
        #expect(state.reviewSession == nil)
    }

    @Test func refine_success_replacesUpdatesHistoryAndKeepsSession() async {
        let (pipe, state, llm, injector, history) = makeRefinePipeline()
        pipe.startRecording(); state.lastPeakLevel = 0.5; await pipe.finalizeRecording()
        #expect(history.items.first?.cleanedText == "cleaned")

        llm.nextResult = .success("tighter")
        await pipe.refine(.terser)

        #expect(llm.calls.last?.refinement == .terser)
        #expect(llm.calls.last?.transcript == "hello world")   // from transcript, not cleaned output
        #expect(injector.replaceCalls.last?.old == "cleaned")
        #expect(injector.replaceCalls.last?.new == "tighter")
        #expect(state.reviewSession?.insertedText == "tighter")
        #expect(history.items.count == 1)
        #expect(history.items.first?.cleanedText == "tighter")
        if case .idle = state.status {} else { Issue.record("expected .idle after refine") }
    }

    @Test func refine_fallbackClipboard_setsToastAndUpdatesText() async {
        let (pipe, state, llm, injector, _) = makeRefinePipeline()
        pipe.startRecording(); state.lastPeakLevel = 0.5; await pipe.finalizeRecording()
        injector.replaceOutcome = .fallbackClipboard
        llm.nextResult = .success("tighter")

        await pipe.refine(.terser)

        #expect(state.reviewSession?.insertedText == "tighter")
        #expect(state.toastMessage == "Copied — ⌘V to replace")
    }

    @Test func refine_llmError_keepsSessionAndSurfacesToast() async {
        let (pipe, state, llm, injector, _) = makeRefinePipeline()
        pipe.startRecording(); state.lastPeakLevel = 0.5; await pipe.finalizeRecording()
        llm.nextResult = .failure(LLMError.missingAPIKey)

        await pipe.refine(.longer)

        #expect(state.reviewSession != nil)
        #expect(state.reviewSession?.insertedText == "cleaned")  // unchanged
        #expect(injector.replaceCalls.isEmpty)
        #expect(state.toastMessage != nil)
        if case .idle = state.status {} else { Issue.record("expected .idle after refine error") }
    }

    @Test func refine_noSession_isNoOp() async {
        let (pipe, state, llm, _, _) = makeRefinePipeline()
        #expect(state.reviewSession == nil)
        await pipe.refine(.terser)
        #expect(llm.calls.isEmpty)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/CapturePipelineTests`
Expected: FAIL to build — `reviewLingerDuration`/`now` init params, `refine`, `expireReview` are undefined.

- [ ] **Step 3: Add stored properties and init params**

In `voxline/Pipeline/CapturePipeline.swift`, add stored properties after `contextTask` (line 18):

```swift
    private var reviewExpiryTask: Task<Void, Never>?
    private let reviewLingerDuration: TimeInterval
    private let now: @Sendable () -> Date
```

Change the `init` signature (lines 20-31) to append the two new parameters before the closing `)`:

```swift
        historyStore: DictationHistoryStore,
        contextCapture: ContextCapturing,
        reviewLingerDuration: TimeInterval = 7,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
```

And assign them inside `init` (after `self.contextCapture = contextCapture`, line 41):

```swift
        self.reviewLingerDuration = reviewLingerDuration
        self.now = now
```

- [ ] **Step 4: Clear the session on a new chord press**

In `startRecording()`, add a call right after the re-entry `switch` block (after line 70's `}`, before `do { try capture.start() ... }`):

```swift
        // A new dictation supersedes any pending refinement offer.
        clearReviewSession()
```

- [ ] **Step 5: Open a session after a successful paste**

In `finalizeRecording()`, replace the paste block + final `resetIdle()` (lines 167-176) with:

```swift
        // 4. Paste.
        do {
            _ = try await injector.inject(cleaned)
        } catch let e as TextInsertionError {
            return setError(e.errorDescription ?? "Text insertion failed.", permissions: e == .accessibilityNotGranted)
        } catch {
            return setError("Text insertion failed: \(error.localizedDescription)")
        }

        // Offer quick refinements: keep the pill alive for a few seconds.
        startReviewSession(transcript: transcript, mode: mode, context: context, insertedText: cleaned)
        resetIdle()
```

- [ ] **Step 6: Add the session + refine methods**

In `voxline/Pipeline/CapturePipeline.swift`, add these methods after `finalizeRecording()` closes (after line 177), before the private `cancelContextTask()` helper:

```swift
    /// Re-run cleanup on the current review session's transcript with a
    /// refinement directive, then swap the result in place. No-op unless a
    /// session is open and we're idle. On failure the session and the pasted
    /// text are left untouched so the click is retryable.
    func refine(_ directive: RefinementDirective) async {
        guard let session = state.reviewSession, case .idle = state.status else { return }
        pauseReviewExpiry()
        state.status = .thinking

        let cleaned: String
        do {
            cleaned = try await llm.cleanup(
                transcript: session.transcript, mode: session.mode,
                context: session.context, refinement: directive
            )
        } catch let e as LLMError {
            state.status = .idle
            showToast(e.errorDescription ?? "Refinement failed.")
            resumeReviewExpiry()
            return
        } catch {
            state.status = .idle
            showToast("Refinement failed: \(error.localizedDescription)")
            resumeReviewExpiry()
            return
        }

        let outcome = await injector.replace(session.insertedText, with: cleaned)
        state.status = .idle
        historyStore.updateMostRecent(cleanedText: cleaned)
        state.reviewSession?.insertedText = cleaned
        if case .fallbackClipboard = outcome {
            showToast("Copied — ⌘V to replace")
        }
        resumeReviewExpiry()
    }

    /// Dismiss the refinement offer (pill × button).
    func dismissReview() { expireReview() }

    /// Scrub the session and its expiry timer. Idempotent.
    func expireReview() {
        reviewExpiryTask?.cancel()
        reviewExpiryTask = nil
        state.reviewSession = nil
    }

    /// Suspend the expiry countdown (pill hover-in) so a session isn't scrubbed
    /// out from under the pointer.
    func pauseReviewExpiry() {
        reviewExpiryTask?.cancel()
        reviewExpiryTask = nil
    }

    /// Resume the countdown from a full window (pill hover-out, or after a
    /// refine completes). No-op if no session is open.
    func resumeReviewExpiry() {
        guard state.reviewSession != nil else { return }
        state.reviewSession?.expiresAt = now().addingTimeInterval(reviewLingerDuration)
        scheduleReviewExpiry()
    }

    private func startReviewSession(transcript: String, mode: Mode, context: CapturedContext, insertedText: String) {
        state.reviewSession = ReviewSession(
            transcript: transcript, mode: mode, context: context,
            insertedText: insertedText, expiresAt: now().addingTimeInterval(reviewLingerDuration)
        )
        scheduleReviewExpiry()
    }

    private func clearReviewSession() { expireReview() }

    private func scheduleReviewExpiry() {
        reviewExpiryTask?.cancel()
        let duration = reviewLingerDuration
        // Created in a @MainActor context, so the closure hops back to MainActor.
        reviewExpiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.expireReview()
        }
    }

    private func showToast(_ message: String) {
        state.toastMessage = message
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self else { return }
            if self.state.toastMessage == message { self.state.toastMessage = nil }
        }
    }
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/CapturePipelineTests`
Expected: PASS.

- [ ] **Step 8: Run the full pipeline/injector/LLM suites for regressions**

Run: `xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/CapturePipelineTests -only-testing:voxlineTests/CapturePipelineErrorTaxonomyTests -only-testing:voxlineTests/ClipboardInjectorTests -only-testing:voxlineTests/ClipboardInjectorReplaceTests -only-testing:voxlineTests/DictationHistoryStoreTests -only-testing:voxlineTests/LLMServiceTests`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add voxline/Pipeline/CapturePipeline.swift voxlineTests/CapturePipelineTests.swift
git commit -m "feat: add review session and refine flow to CapturePipeline

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: Pill UI + window interactivity + app wiring

This task is UI and app-wiring; its deliverable is verified by build + a full test run + manual smoke (there's no automated harness for cross-app AX / NSPanel behavior).

**Files:**
- Create: `voxline/UI/PillReviewActions.swift`
- Modify: `voxline/UI/RecordingPillView.swift` (review appearance)
- Modify: `voxline/UI/RecordingPillWindow.swift` (interactivity, sizing, visibility predicate, `show` signature)
- Modify: `voxline/voxlineApp.swift` (build actions, pass to `show`, observe `reviewSession`)

**Interfaces:**
- Consumes: `AppState.reviewSession`, `RefinementDirective`, `CapturePipeline.refine/dismissReview/pauseReviewExpiry/resumeReviewExpiry`.
- Produces: `struct PillReviewActions` (MainActor closures); `RecordingPillWindow.show(state:actions:)`.

- [ ] **Step 1: Create `PillReviewActions`**

Create `voxline/UI/PillReviewActions.swift`:

```swift
import Foundation

/// Callbacks the review pill invokes. Wired to `CapturePipeline` in
/// `voxlineApp`. Defaults are no-ops so previews / tests can omit them.
@MainActor
struct PillReviewActions {
    var refine: (RefinementDirective) -> Void = { _ in }
    var dismiss: () -> Void = {}
    var hoverChanged: (Bool) -> Void = { _ in }
}
```

- [ ] **Step 2: Update `RecordingPillView` for the review appearance**

Replace the whole body of `voxline/UI/RecordingPillView.swift` (lines 1-40, the `RecordingPillView` struct — leave `WaveformBars` below it unchanged) with:

```swift
import SwiftUI

/// Small floating pill showing recording state, an animated waveform, or —
/// after a dictation completes — quick refinement actions.
struct RecordingPillView: View {
    @Bindable var state: AppState
    var actions: PillReviewActions = PillReviewActions()

    var body: some View {
        Group {
            switch state.status {
            case .recording:
                HStack(spacing: 10) {
                    WaveformBars(level: state.audioLevel)
                    Text(elapsed)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .monospacedDigit()
                }
            case .thinking:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(state.reviewSession != nil ? "Refining…" : "Transcribing…")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                }
            default:
                if state.reviewSession != nil {
                    ReviewControls(state: state, actions: actions)
                } else if let toast = state.toastMessage {
                    Text(toast)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                } else {
                    EmptyView()
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .frame(height: 32)
    }

    private var elapsed: String {
        guard let startedAt = state.recordingStartedAt else { return "0.0s" }
        let s = Date().timeIntervalSince(startedAt)
        return String(format: "%.1fs", s)
    }
}

/// The three refinement buttons + dismiss. Hovering anywhere over the row
/// pauses the auto-dismiss countdown. An optional caption line surfaces the
/// "Copied — ⌘V to replace" / error toast without hiding the buttons.
private struct ReviewControls: View {
    @Bindable var state: AppState
    let actions: PillReviewActions

    var body: some View {
        VStack(spacing: 2) {
            if let toast = state.toastMessage {
                Text(toast)
                    .font(.system(size: 10, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                button("Terser") { actions.refine(.terser) }
                button("Longer") { actions.refine(.longer) }
                button("Clearer") { actions.refine(.clearer) }
                Button(action: { actions.dismiss() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }
        }
        .onHover { actions.hoverChanged($0) }
    }

    private func button(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .buttonStyle(.plain)
    }
}
```

Note the fixed `width: 140` is intentionally dropped from the frame — the panel now owns width per state (next step). `WaveformBars` (originally lines 42-65) stays exactly as-is.

- [ ] **Step 3: Update `RecordingPillWindow` — actions, sizing, interactivity, visibility**

In `voxline/UI/RecordingPillWindow.swift`:

Add a stored property after `hostingView` (line 8):

```swift
    private var actions = PillReviewActions()
```

Change `show(state:)` (line 10) to `show(state:actions:)` and pass the actions into the view. Replace lines 10-16:

```swift
    func show(state: AppState) {
        if panel != nil {
            updateVisibility(state: state)
            return
        }

        let view = RecordingPillView(state: state)
```

with:

```swift
    func show(state: AppState, actions: PillReviewActions = PillReviewActions()) {
        self.actions = actions
        if panel != nil {
            updateVisibility(state: state)
            return
        }

        let view = RecordingPillView(state: state, actions: actions)
```

Replace `updateVisibility(state:)` (lines 41-58) with:

```swift
    func updateVisibility(state: AppState) {
        guard let panel else { return }
        let recordingOrThinking: Bool = {
            switch state.status {
            case .recording, .thinking: return true
            default: return false
            }
        }()
        let inReview = (state.reviewSession != nil)
        let hasToast = (state.toastMessage != nil)

        // The review pill must be clickable; every other state is click-through.
        panel.ignoresMouseEvents = !inReview

        // Review needs room for three buttons + dismiss; other states are compact.
        let width: CGFloat = inReview ? 300 : 140
        if panel.frame.width != width {
            var frame = panel.frame
            frame.size.width = width
            panel.setFrame(frame, display: false)
        }

        if recordingOrThinking || inReview || hasToast {
            if !panel.isVisible {
                repositionNearMouse(panel: panel)
                panel.orderFrontRegardless()
            }
        } else {
            panel.orderOut(nil)
        }
    }
```

- [ ] **Step 4: Wire actions and observation in `voxlineApp`**

In `voxline/voxlineApp.swift`, replace the pill creation (lines 258-260):

```swift
        let pill = RecordingPillWindow()
        pillWindow = pill
        pill.show(state: state)
```

with:

```swift
        let pill = RecordingPillWindow()
        pillWindow = pill
        let pillActions = PillReviewActions(
            refine: { [weak self] directive in
                Task { @MainActor in await self?.pipeline?.refine(directive) }
            },
            dismiss: { [weak self] in self?.pipeline?.dismissReview() },
            hoverChanged: { [weak self] hovering in
                if hovering { self?.pipeline?.pauseReviewExpiry() }
                else { self?.pipeline?.resumeReviewExpiry() }
            }
        )
        pill.show(state: state, actions: pillActions)
```

Then add a `reviewSession` observer next to the existing toast observer. After line 319 (`observeToastChanges(state: state)`), add:

```swift
        observeReviewSessionChanges(state: state)
```

And add the method itself next to `observeToastChanges` (after it closes at line 402):

```swift

    /// Re-runs `pillWindow.updateVisibility` whenever `state.reviewSession`
    /// changes, so the pill flips clickable/sized when a refinement offer opens
    /// and back to click-through when it's scrubbed.
    private func observeReviewSessionChanges(state: AppState) {
        withObservationTracking {
            _ = state.reviewSession
        } onChange: { [weak self, weak state] in
            Task { @MainActor in
                guard let self, let state else { return }
                self.pillWindow?.updateVisibility(state: state)
                self.observeReviewSessionChanges(state: state)
            }
        }
    }
```

- [ ] **Step 5: Build and run the full test suite**

Run: `xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS'`
Expected: BUILD SUCCEEDS and all suites PASS.

- [ ] **Step 6: Manual smoke test**

Build and install: `./scripts/build-local.sh`. Then:
1. Dictate a sentence into TextEdit. Confirm the pill lingers with **Terser · Longer · Clearer · ×**.
2. Click **Terser** — confirm the text is replaced in place, focus never leaves TextEdit, and the pill returns to the buttons.
3. Hover the pill for >7s — confirm it does NOT dismiss while hovered, and dismisses ~7s after you move away.
4. Dictate into Slack, click **Clearer** — confirm in-place replace.
5. Dictate into a Google Docs field in Chrome (canvas editor), click **Longer** — confirm the fallback toast "Copied — ⌘V to replace" appears and ⌘V inserts the refined text.
6. Press the dictation chord while the pill is showing — confirm the pill dismisses and a new recording starts.

- [ ] **Step 7: Commit**

```bash
git add voxline/UI/PillReviewActions.swift voxline/UI/RecordingPillView.swift voxline/UI/RecordingPillWindow.swift voxline/voxlineApp.swift
git commit -m "feat: post-dictation refine actions in the recording pill

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Notes for the implementer

- **Line numbers** are from `main` at the plan-writing commit and will drift as you edit. Anchor on the quoted surrounding code, not the numbers.
- **`FakeContextCapture`** is already defined in `CapturePipelineTests.swift` (used by `makePipeline`); reuse it in `makeRefinePipeline`.
- **`LLMError`** is the existing error type thrown by `LLMService`; `.missingAPIKey` is a real case (see `LLMServiceTests`). `errorDescription` comes from its `LocalizedError` conformance.
- **Do not** add `@MainActor` to `refine`'s `Task` bodies by hand — `CapturePipeline` is already `@MainActor`, so `Task { … }` inherits it.
- If any *existing* `CapturePipelineTests` assertion breaks because it compared `llm.calls[i]` as a whole tuple, update it to read the named fields (`.transcript`, `.mode`, `.context`, `.refinement`) — the added field is the only change.
