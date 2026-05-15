# ClipboardInjector top-3 bugfixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix three correctness bugs in `voxline/Output/ClipboardInjector.swift` surfaced in the 2026-05-15 main-branch review: (1) chord-release predicate hardcodes Ctrl/Alt and misfires for Cmd/Shift chords; (2) pasteboard restore relies on duplicated `catch`-and-happy-path calls instead of `defer`, making future regressions easy; (3) paste-success verification accepts `.unchanged` AX results unconditionally, masking real failures when focus shifts mid-paste.

**Architecture:**
- Issue 1: replace the hardcoded `defaultChordIsHeld` closure with a factory that takes a `chord` provider and consults `HotkeyChord.Modifier.deviceMaskBit`. Production wires the factory in `AppCoordinator` with a live closure reading `settings.hotkeyChord`. Tests keep their existing `chordIsHeld: { ... }` override seam.
- Issue 2: replace the dual restore call (`do { … snapshot.restore(...); switch … } catch { snapshot.restore(...); throw }`) with a single `defer { snapshot.restore(to: pasteboard) }` placed immediately after snapshot capture. Restoration becomes unconditional and resilient to any future throwing line inserted into the body.
- Issue 3: extend `FocusedTextSystem` with `focusedElementIdentity() -> AnyHashable?`. The AX implementation returns a hashable wrapping the focused `AXUIElement` (`CFEqual`/`CFHash` semantics). When the post-paste AX value matches the pre-paste value (`.unchanged`), the injector now consults element identity: same element → keep `.unverified` (Electron/WKWebView stale-AX path, current behavior preserved); different element → throw new `TextInsertionError.pasteVerificationFailed`. The fallback chain (AX value-set, synthetic typing) is **not** invoked because those strategies would write into the *new* focused target, which is a worse outcome than a clear error to the user.

**Tech Stack:** Swift 5.9+, AppKit, ApplicationServices (AX), CoreGraphics, Swift Testing (`@Suite`, `@Test`).

---

## File structure

**Modify:**
- `voxline/Output/ClipboardInjector.swift` — chord predicate factory, defer-based restore, identity-aware verification, new error case, extended `FocusedTextSystem` protocol + `AXFocusedTextSystem` impl.
- `voxline/voxlineApp.swift` (~line 195-198) — wire chord provider into `ClipboardInjector` init.
- `voxlineTests/ClipboardInjectorTests.swift` — extend `FakeFocusedTextSystem` with identity stub; add tests per issue.

**Create:** none.

---

## Task 1: Add failing test for chord-aware held predicate

**Files:**
- Test: `voxlineTests/ClipboardInjectorTests.swift`
- Reference: `voxline/Hotkey/HotkeyChord.swift:22-33` (`Modifier.deviceMaskBit`)

- [ ] **Step 1: Write the failing test**

Add the following test inside `@Suite struct ClipboardInjectorTests` in `voxlineTests/ClipboardInjectorTests.swift` (append before the closing `}` of the suite):

```swift
@Test func chord_held_predicate_uses_chord_specific_device_bits() {
    // Cmd+Shift chord — neither bit overlaps the Ctrl/Alt bits the old
    // hardcoded predicate consulted. The chord-aware factory must report
    // "held" when the right Cmd bit is set, and "not held" when only the
    // (unrelated) Control bit is set.
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
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```
xcodebuild test -project voxline.xcodeproj -scheme voxline -only-testing:voxlineTests/ClipboardInjectorTests/chord_held_predicate_uses_chord_specific_device_bits 2>&1 | tail -40
```
Expected: compile error — `ClipboardInjector.chordIsHeld(in:chord:)` does not exist.

- [ ] **Step 3: Implement the chord-aware predicate**

In `voxline/Output/ClipboardInjector.swift`, locate lines 324-327:

```swift
nonisolated static let defaultChordIsHeld: @Sendable () -> Bool = {
    let flags = CGEventSource.flagsState(.combinedSessionState)
    return flags.contains(.maskControl) || flags.contains(.maskAlternate)
}
```

Replace with:

```swift
/// Pure predicate: is the given chord considered "held" under `flags`?
/// Consults the per-device modifier bits the OS publishes on flagsChanged
/// events (NX_DEVICE*KEYMASK), matching what HotkeyMonitor's tap callback
/// uses. Static so it can be unit-tested without a ClipboardInjector
/// instance and without consulting the live session state.
nonisolated static func chordIsHeld(in flags: CGEventFlags, chord: HotkeyChord) -> Bool {
    let bitA = CGEventFlags(rawValue: chord.modifierA.deviceMaskBit)
    let bitB = CGEventFlags(rawValue: chord.modifierB.deviceMaskBit)
    return flags.contains(bitA) || flags.contains(bitB)
}

/// Factory: returns a closure that reads the live session-wide modifier
/// state and asks `chordIsHeld(in:chord:)` whether the chord (resolved
/// at each call from `chord()`) is currently down. The closure-of-a-closure
/// shape lets the chord be updated at runtime (Settings → Hotkey) without
/// rebuilding ClipboardInjector.
nonisolated static func makeChordIsHeld(chord: @escaping @Sendable () -> HotkeyChord) -> @Sendable () -> Bool {
    {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        return chordIsHeld(in: flags, chord: chord())
    }
}

/// Default predicate used when no chord-aware variant is supplied (e.g.
/// tests that don't care about the modifier logic). Always returns
/// false — the safest default: the injector treats the chord as already
/// released and posts Cmd+V immediately. Production code MUST override
/// via `makeChordIsHeld(chord:)`.
nonisolated static let defaultChordIsHeld: @Sendable () -> Bool = { false }
```

- [ ] **Step 4: Run test to verify it passes**

Run:
```
xcodebuild test -project voxline.xcodeproj -scheme voxline -only-testing:voxlineTests/ClipboardInjectorTests/chord_held_predicate_uses_chord_specific_device_bits 2>&1 | tail -20
```
Expected: PASS.

- [ ] **Step 5: Commit**

```
git add voxline/Output/ClipboardInjector.swift voxlineTests/ClipboardInjectorTests.swift
git commit -m "$(cat <<'EOF'
fix(paste): derive chord-held predicate from HotkeyChord device bits

Replaces the hardcoded `.maskControl || .maskAlternate` check, which
silently passed for any chord involving .command/.shift and posted
synthetic Cmd+V while the user was still physically holding modifiers.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Wire chord provider through AppCoordinator

**Files:**
- Modify: `voxline/voxlineApp.swift:195-198`

- [ ] **Step 1: Update ClipboardInjector wiring**

In `voxline/voxlineApp.swift`, replace lines 195-198:

```swift
let injector = ClipboardInjector(
    focusedTextSystem: focusedTextSystem,
    pasteEligibility: DefaultPasteEligibility(focusedTextSystem: focusedTextSystem)
)
```

with:

```swift
// Capture settings by value so the closure reads the *current* chord
// each time the paste-release wait polls. AppSettings is a struct over
// UserDefaults; re-instantiating per-call is cheap and avoids a stale
// snapshot if the user changes the chord while a dictation is in flight.
let chordProvider: @Sendable () -> HotkeyChord = { AppSettings().hotkeyChord }
let injector = ClipboardInjector(
    focusedTextSystem: focusedTextSystem,
    pasteEligibility: DefaultPasteEligibility(focusedTextSystem: focusedTextSystem),
    chordIsHeld: ClipboardInjector.makeChordIsHeld(chord: chordProvider)
)
```

- [ ] **Step 2: Verify the project builds**

Run:
```
xcodebuild build -project voxline.xcodeproj -scheme voxline 2>&1 | tail -20
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Run the full ClipboardInjector test suite**

Run:
```
xcodebuild test -project voxline.xcodeproj -scheme voxline -only-testing:voxlineTests/ClipboardInjectorTests 2>&1 | tail -30
```
Expected: all existing tests still PASS (they inject their own `chordIsHeld` so they're unaffected).

- [ ] **Step 4: Commit**

```
git add voxline/voxlineApp.swift
git commit -m "$(cat <<'EOF'
fix(paste): wire live chord provider into ClipboardInjector

Production wiring now reads HotkeyChord from AppSettings on every
paste-release poll, so the chord-aware predicate added in the previous
commit gets a live source of truth.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Add regression test for defer-guaranteed restore

**Files:**
- Test: `voxlineTests/ClipboardInjectorTests.swift`

- [ ] **Step 1: Write the failing test**

Append inside `@Suite struct ClipboardInjectorTests`:

```swift
/// Regression test for defer-based restore: cancellation between the
/// post-paste settle delay and the AX verification read must still
/// restore the original clipboard. The old catch-only structure handled
/// this via the catch; the defer-based structure handles it implicitly.
/// This test pins both behaviors so a future refactor that drops one
/// guarantee gets caught.
@Test func paste_path_restores_clipboard_when_cancelled_after_postkey() async throws {
    let board = makeBoard()
    board.clearContents()
    board.setString("ORIGINAL", forType: .string)

    let postedAt = LockedBox<Date?>(nil)
    let injector = await ClipboardInjector(
        pasteboard: board,
        focusedTextSystem: FakeFocusedTextSystem(),
        chordIsHeld: { false },
        forceClearChord: {},
        postKey: { _, _ in postedAt.write(Date()) },
        pasteVirtualKeyCode: { 9 },
        typeText: { _ in },
        isAccessibilityTrusted: { true },
        chordReleaseTimeout: .seconds(60),
        chordPollInterval: .milliseconds(5),
        // Long restoreDelay so we can cancel between postKey and the
        // AX verification read.
        restoreDelay: .seconds(60),
        verificationDelay: .milliseconds(0)
    )

    let task = Task { try await injector.inject("SECRET") }
    // Wait until postKey has been observed, then cancel.
    for _ in 0..<200 {
        if postedAt.read() != nil { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(postedAt.read() != nil, "postKey should have fired before cancellation")
    task.cancel()
    _ = try? await task.value

    #expect(board.string(forType: .string) == "ORIGINAL")
}
```

- [ ] **Step 2: Run test to verify it passes against today's code**

Run:
```
xcodebuild test -project voxline.xcodeproj -scheme voxline -only-testing:voxlineTests/ClipboardInjectorTests/paste_path_restores_clipboard_when_cancelled_after_postkey 2>&1 | tail -20
```
Expected: PASS. (The current `catch` handler already restores on this path; the test is regression coverage for the upcoming refactor.)

- [ ] **Step 3: Commit**

```
git add voxlineTests/ClipboardInjectorTests.swift
git commit -m "$(cat <<'EOF'
test(paste): pin clipboard-restore on cancel after Cmd+V post

Adds regression coverage so the upcoming defer-based restore refactor
cannot silently drop the restore on any post-Cmd+V cancellation path.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Replace dual restore with defer

**Files:**
- Modify: `voxline/Output/ClipboardInjector.swift:556-595`

- [ ] **Step 1: Apply the refactor**

In `voxline/Output/ClipboardInjector.swift`, replace the body of `injectViaClipboardPaste` from line 556 (the `do {` that opens the post-snapshot block) through line 595 (its closing `}`) with the version below. Specifically, replace this block:

```swift
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
            postKey(pasteVirtualKeyCode(), [.maskCommand])

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
```

with:

```swift
        // From this point on, every exit path — normal return, thrown
        // error, parent-Task cancellation at any await — must restore
        // the snapshot. `defer` runs unconditionally as the scope unwinds,
        // so adding a future throwing line below cannot silently leak
        // the cleaned text on the system clipboard.
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
        case .unavailable, .unchanged:
            // .unchanged here means "AX disagrees that anything changed."
            // That's not proof of failure — many editors expose stale
            // values via AX. Treat as unverified so we don't double-insert
            // on top of a paste that may well have succeeded.
            return TextInsertionOutcome(strategy: .clipboardPaste, verification: .unverified)
        }
```

- [ ] **Step 2: Run the full ClipboardInjector test suite**

Run:
```
xcodebuild test -project voxline.xcodeproj -scheme voxline -only-testing:voxlineTests/ClipboardInjectorTests 2>&1 | tail -30
```
Expected: all tests PASS, including:
- `paste_path_restores_clipboard_when_chord_release_is_cancelled` (cancellation pre-postKey)
- `paste_path_restores_clipboard_when_cancelled_after_postkey` (cancellation post-postKey)
- `writes_text_then_posts_cmd_v_then_restores` (happy path)

- [ ] **Step 3: Commit**

```
git add voxline/Output/ClipboardInjector.swift
git commit -m "$(cat <<'EOF'
refactor(paste): guarantee clipboard restore via defer

Replaces the dual `snapshot.restore` calls (happy-path + catch) with a
single defer placed right after snapshot capture. Restoration is now
unconditional on every exit path, including any throwing line added
to the post-snapshot block in the future.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Extend FocusedTextSystem with element identity

**Files:**
- Modify: `voxline/Output/ClipboardInjector.swift:138-146` (protocol), `:203-305` (AX impl)

- [ ] **Step 1: Add the protocol requirement**

In `voxline/Output/ClipboardInjector.swift`, extend the `FocusedTextSystem` protocol (currently lines 138-146):

```swift
protocol FocusedTextSystem: Sendable {
    func snapshot() -> FocusedTextSnapshot?
    func checkInsertion(before: FocusedTextSnapshot?, insertedText: String) -> FocusedTextCheck
    func insertText(_ text: String) throws
    /// True when the focused element is a secure text field (password input).
    /// `inject()` short-circuits in this case so dictated text never lands in
    /// a password store via paste, AX value-set, or synthetic typing.
    func focusedFieldIsSecure() -> Bool
}
```

Add one new requirement just before the closing `}`:

```swift
    /// Opaque identity of the currently focused element. Compared by
    /// the paste-path verification to distinguish "AX returned a stale
    /// value but focus is still our target" (Electron/WKWebView quirk)
    /// from "focus shifted between the pre- and post-paste reads"
    /// (the Cmd+V landed somewhere unintended). Returns nil when no
    /// element is focused or the platform cannot vend an identity.
    func focusedElementIdentity() -> AnyHashable?
```

- [ ] **Step 2: Implement on AXFocusedTextSystem**

Add this method to `AXFocusedTextSystem` (insert after `focusedFieldIsSecure()` near line 228):

```swift
    func focusedElementIdentity() -> AnyHashable? {
        guard let element = focusedElement() else { return nil }
        // AXUIElement is a CFType; CFHash + CFEqual reflect element
        // identity. Wrapping in a struct that hashes via CFHash and
        // equates via CFEqual makes it an AnyHashable that compares
        // by the underlying UI element, not by Swift's default
        // CFType pointer equality (which is already CFEqual, but is
        // not Sendable through AnyHashable without a wrapper).
        return AnyHashable(AXElementIdentity(element: element))
    }
```

Add this supporting struct at file scope, immediately after the `AXFocusedTextSystem` struct closes (around line 305 today, before the `@MainActor final class ClipboardInjector`):

```swift
/// Hashable wrapper over an AXUIElement so it can be stored in an
/// AnyHashable. CFHash/CFEqual provide the underlying identity.
private struct AXElementIdentity: Hashable, @unchecked Sendable {
    let element: AXUIElement

    static func == (lhs: AXElementIdentity, rhs: AXElementIdentity) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(element))
    }
}
```

- [ ] **Step 3: Update FakeFocusedTextSystem in tests**

In `voxlineTests/ClipboardInjectorTests.swift`, extend `FakeFocusedTextSystem` (lines 20-47) by adding an identity queue and the conformance method. Add these stored properties:

```swift
        var identityQueue: [AnyHashable?] = []
        var currentIdentity: AnyHashable? = "default-element"
```

(insert these just below the existing `var isSecure = false` line.)

And add this method just before the closing `}` of `FakeFocusedTextSystem`:

```swift
        func focusedElementIdentity() -> AnyHashable? {
            if !identityQueue.isEmpty {
                return identityQueue.removeFirst()
            }
            return currentIdentity
        }
```

- [ ] **Step 4: Verify the project builds**

Run:
```
xcodebuild build -project voxline.xcodeproj -scheme voxline 2>&1 | tail -20
```
Expected: BUILD SUCCEEDED.

Run:
```
xcodebuild test -project voxline.xcodeproj -scheme voxline -only-testing:voxlineTests/ClipboardInjectorTests 2>&1 | tail -30
```
Expected: all tests PASS (no behavior change yet — only the protocol/impl plumbing).

- [ ] **Step 5: Commit**

```
git add voxline/Output/ClipboardInjector.swift voxlineTests/ClipboardInjectorTests.swift
git commit -m "$(cat <<'EOF'
refactor(paste): add focusedElementIdentity to FocusedTextSystem

Plumbs an opaque, CFEqual-backed identity for the focused AX element
through the FocusedTextSystem protocol and the test fake. No behavior
change yet — the next commit consumes the identity in paste verification.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Add failing tests for identity-aware paste verification

**Files:**
- Test: `voxlineTests/ClipboardInjectorTests.swift`

- [ ] **Step 1: Write the failing tests**

Append both tests inside `@Suite struct ClipboardInjectorTests`:

```swift
@Test func paste_with_ax_unchanged_and_same_element_remains_unverified() async throws {
    // Electron/WKWebView path: AX exposes a stale value AND the focused
    // element is the same one we sampled before the paste. We must NOT
    // escalate (would double-insert on top of a paste that likely
    // succeeded). Behavior identical to today's `.unverified` outcome.
    let board = makeBoard()
    board.clearContents()
    board.setString("ORIGINAL", forType: .string)

    let focused = FakeFocusedTextSystem()
    focused.currentValue = "before"
    focused.snapshotQueue = [
        FocusedTextSnapshot(value: "before"),
        FocusedTextSnapshot(value: "before")
    ]
    focused.identityQueue = ["webview-1", "webview-1"]

    let injector = await ClipboardInjector(
        pasteboard: board,
        focusedTextSystem: focused,
        chordIsHeld: { false },
        forceClearChord: {},
        postKey: { _, _ in },
        pasteVirtualKeyCode: { 9 },
        typeText: { _ in },
        isAccessibilityTrusted: { true },
        restoreDelay: .milliseconds(0)
    )

    let outcome = try await injector.inject("CLEAN")

    #expect(outcome == TextInsertionOutcome(strategy: .clipboardPaste, verification: .unverified))
    #expect(focused.inserted.isEmpty)   // did NOT double-insert via AX
    #expect(board.string(forType: .string) == "ORIGINAL")
}

@Test func paste_with_ax_unchanged_and_different_element_surfaces_failure() async throws {
    // Focus shifted between the pre- and post-paste reads. The paste
    // landed somewhere we didn't intend, and AX value is unchanged for
    // the new focus target. We must NOT fall back (would write into the
    // new focus target). Surface a clear failure so the user can retry.
    let board = makeBoard()
    board.clearContents()
    board.setString("ORIGINAL", forType: .string)

    let focused = FakeFocusedTextSystem()
    focused.currentValue = "before"
    focused.snapshotQueue = [
        FocusedTextSnapshot(value: "before"),
        FocusedTextSnapshot(value: "before")
    ]
    focused.identityQueue = ["element-A", "element-B"]   // focus shifted

    let typed = LockedBox<[String]>([])
    let injector = await ClipboardInjector(
        pasteboard: board,
        focusedTextSystem: focused,
        chordIsHeld: { false },
        forceClearChord: {},
        postKey: { _, _ in },
        pasteVirtualKeyCode: { 9 },
        typeText: { text in typed.mutate { $0.append(text) } },
        isAccessibilityTrusted: { true },
        restoreDelay: .milliseconds(0)
    )

    await #expect(throws: TextInsertionError.pasteVerificationFailed) {
        _ = try await injector.inject("CLEAN")
    }

    // No fallback ran — neither AX value-set nor synthetic typing.
    #expect(focused.inserted.isEmpty)
    #expect(typed.read().isEmpty)
    // Clipboard restored even on the failure path.
    #expect(board.string(forType: .string) == "ORIGINAL")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:
```
xcodebuild test -project voxline.xcodeproj -scheme voxline -only-testing:voxlineTests/ClipboardInjectorTests/paste_with_ax_unchanged_and_different_element_surfaces_failure 2>&1 | tail -20
```
Expected: compile error — `TextInsertionError.pasteVerificationFailed` does not exist. The first test also fails because the existing logic returns `.unverified` regardless of identity (so it will still pass that case but the AX-fallback short-circuit doesn't exist yet — the first test should currently pass because today's code returns `.unverified` and doesn't fall back to AX in the `.unchanged` branch).

- [ ] **Step 3: Commit**

```
git add voxlineTests/ClipboardInjectorTests.swift
git commit -m "$(cat <<'EOF'
test(paste): add identity-aware paste verification expectations

Pins the two future branches:
- same-element + AX-unchanged → unverified (Electron path preserved)
- different-element + AX-unchanged → pasteVerificationFailed thrown

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Implement identity-aware paste verification

**Files:**
- Modify: `voxline/Output/ClipboardInjector.swift` (TextInsertionError enum + injectViaClipboardPaste verification switch)

- [ ] **Step 1: Add the new error case**

In `voxline/Output/ClipboardInjector.swift`, locate the `TextInsertionError` enum (lines 168-201). Add a new case after `case secureFieldUnsupported`:

```swift
    case pasteVerificationFailed
```

And add the matching `errorDescription` branch in the switch (after `secureFieldUnsupported`'s branch):

```swift
        case .pasteVerificationFailed:
            return "Voxline could not confirm the paste landed in the focused field. Click the field you want to dictate into and try again."
```

- [ ] **Step 2: Capture pre-paste identity**

In `injectViaClipboardPaste`, just after the existing `let before = focusedTextSystem.snapshot()` line (currently line 539), add:

```swift
        let beforeIdentity = focusedTextSystem.focusedElementIdentity()
```

- [ ] **Step 3: Update the verification switch**

In `injectViaClipboardPaste`, replace the current verification switch (now post-Task-4 refactor):

```swift
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
```

with:

```swift
        switch check {
        case .confirmedChanged:
            return TextInsertionOutcome(strategy: .clipboardPaste, verification: .confirmed)
        case .unavailable:
            // No before/after snapshot to compare. Many opaque editors
            // (Electron, WKWebView, custom NSTextView) take this path
            // and a paste likely did land — escalating would double-insert.
            return TextInsertionOutcome(strategy: .clipboardPaste, verification: .unverified)
        case .unchanged:
            // AX disagrees that anything changed. Two cases to disambiguate:
            //   (a) Same focused element as before → stale-AX quirk in the
            //       focused editor. Paste probably landed; do NOT escalate.
            //   (b) Different focused element → focus shifted between the
            //       pre- and post-paste reads. The Cmd+V landed somewhere
            //       we didn't intend. Fallback strategies would compound
            //       the problem by writing into the new focus target.
            //       Surface a clear failure instead.
            let afterIdentity = focusedTextSystem.focusedElementIdentity()
            if let beforeIdentity, let afterIdentity, beforeIdentity != afterIdentity {
                throw TextInsertionError.pasteVerificationFailed
            }
            return TextInsertionOutcome(strategy: .clipboardPaste, verification: .unverified)
        }
```

- [ ] **Step 4: Make sure pasteVerificationFailed is NOT swallowed by inject()'s fallback**

Locate the `inject(_:)` method (currently around line 490). The current shape catches every paste error and falls through to AX. We want `pasteVerificationFailed` to propagate, not retry.

Replace the first `do { … } catch { … }` block in `inject(_:)`:

```swift
        do {
            return try await injectViaClipboardPaste(text)
        } catch {
            AppLog.paste.debug("clipboard-paste failed: \(error.localizedDescription); trying AX value-set")
            failures.append(error.localizedDescription)
        }
```

with:

```swift
        do {
            return try await injectViaClipboardPaste(text)
        } catch TextInsertionError.pasteVerificationFailed {
            // Focus shifted mid-paste; the cleaned text landed in an
            // unintended target. Fallback strategies would write into the
            // new focus, compounding the harm. Surface the error directly.
            AppLog.paste.error("paste verification failed: focused element changed mid-paste")
            throw TextInsertionError.pasteVerificationFailed
        } catch {
            AppLog.paste.debug("clipboard-paste failed: \(error.localizedDescription); trying AX value-set")
            failures.append(error.localizedDescription)
        }
```

- [ ] **Step 5: Run the full ClipboardInjector test suite**

Run:
```
xcodebuild test -project voxline.xcodeproj -scheme voxline -only-testing:voxlineTests/ClipboardInjectorTests 2>&1 | tail -40
```
Expected: all tests PASS, including the two new identity-aware tests from Task 6. Verify in particular:
- `paste_with_ax_unchanged_returns_unverified_and_does_not_double_insert` (legacy test) still passes — its `FakeFocusedTextSystem` returns the same `currentIdentity` for both reads, exercising the Electron path.
- `paste_with_ax_unchanged_and_different_element_surfaces_failure` passes.

If `paste_with_ax_unchanged_returns_unverified_and_does_not_double_insert` regresses, the legacy fake fixture is missing the new `currentIdentity` default (which Task 5 set to `"default-element"`); confirm that's intact.

- [ ] **Step 6: Commit**

```
git add voxline/Output/ClipboardInjector.swift
git commit -m "$(cat <<'EOF'
fix(paste): differentiate stale-AX from focus-shift on .unchanged

When AX reports no change after a synthetic Cmd+V we now check whether
the focused element is still the one we sampled pre-paste. Same element
keeps the legacy `.unverified` outcome (Electron / WKWebView stale-AX
case). Different element throws pasteVerificationFailed so the user gets
a clear retry signal instead of a silent miss.

The new error is propagated by inject() — fallback strategies would write
into the new (unintended) focus target.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Full regression run and manual smoke

**Files:** none

- [ ] **Step 1: Run the entire test target**

Run:
```
xcodebuild test -project voxline.xcodeproj -scheme voxline 2>&1 | tail -40
```
Expected: all tests PASS. Pay attention to:
- `CapturePipelineTests` (uses an injector indirectly via FakeInjector — unaffected).
- `ClipboardInjectorTests` (all 11+ tests including the 3 new ones).

- [ ] **Step 2: Manual smoke test — Cmd+Shift chord**

1. Build and run voxline.
2. Open Settings → Hotkey → change the chord to something including Cmd or Shift (e.g. `Right Cmd + Right Shift`).
3. Focus a plain `NSTextField` (Spotlight, a Safari URL bar, a Notes note).
4. Hold the new chord, speak a short phrase, release.
5. Verify: the cleaned text appears in the field; no extra Cmd+Shift+V shortcut fired (would be paste-and-match-style in some apps, or "Edit > Paste Special" elsewhere).

- [ ] **Step 3: Manual smoke test — focus shift mid-paste**

1. Build and run voxline with the default chord.
2. Focus a TextField, start dictation.
3. While speaking, click into a different app's text field BEFORE releasing the chord.
4. Release the chord.
5. Verify: voxline surfaces a "could not confirm the paste landed" toast (not a silent miss, not a duplicate insert into the new field).

- [ ] **Step 4: Manual smoke test — Electron app (regression)**

1. Build and run voxline.
2. Focus an Electron-based text input (Slack message composer, Discord, VS Code editor).
3. Dictate a short phrase normally.
4. Verify: text appears once. No double-insert. Outcome in logs is `clipboard paste, unverified`.

- [ ] **Step 5: Commit any final adjustments**

If any of the smoke tests revealed a discrepancy, fix and commit. Otherwise no commit needed.

---

## Self-review checklist

- ✅ Issue 1 (chord predicate): Task 1 (test) + Task 1.step 3 (impl) + Task 2 (production wiring).
- ✅ Issue 2 (defer restore): Task 3 (regression test) + Task 4 (refactor).
- ✅ Issue 3 (verification heuristic): Task 5 (protocol plumbing) + Task 6 (tests) + Task 7 (impl).
- ✅ Task 8 covers full-suite regression + manual smoke for each fix.
- ✅ No placeholders, no TODOs, every code block is complete.
- ✅ Type consistency: `TextInsertionError.pasteVerificationFailed`, `FocusedTextSystem.focusedElementIdentity()`, `ClipboardInjector.chordIsHeld(in:chord:)`, `ClipboardInjector.makeChordIsHeld(chord:)` referenced consistently across tasks.
- ✅ TDD discipline: every behavior change has a failing test before the implementation step.

## Execution

Plan saved. Two execution options exist (subagent-driven for review between tasks, or inline executing-plans for batch). Will await user choice before launching.
