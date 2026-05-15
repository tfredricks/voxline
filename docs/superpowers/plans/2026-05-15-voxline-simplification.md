# Voxline Simplification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Strip enterprise-grade scaffolding from voxline (a personal local Mac app) without changing any user-visible behavior.

**Architecture:** Nine independent simplification passes, ordered safest → riskiest. Each pass is self-contained: it builds, tests, and commits before the next starts. No new abstractions; only removals and collapses. End-user functionality (hotkey → record → transcribe → LLM cleanup → paste) stays bit-for-bit identical.

**Tech Stack:** Swift 5, SwiftUI, Swift Testing (`@Suite`/`@Test`/`#expect`), Xcode, macOS-only menu-bar app.

## Conventions

- After every pass, run the full test suite. Canonical command:
  ```bash
  xcodebuild test \
    -project voxline.xcodeproj \
    -scheme voxline \
    -destination 'platform=macOS,arch=arm64' \
    -quiet 2>&1 | tail -30
  ```
  Expected: `** TEST SUCCEEDED **` near the end.
- All commits go straight to `main` (per repo's branch strategy memory).
- Commit messages: `refactor(simplify): <short description>`.
- Never delete a file that something still references — let the compiler complain first, then prune.

---

## Pass A — Strip `OSSignposter` instrumentation from `CapturePipeline`

**Why:** ~20 lines of `signposter.beginInterval(...)` / `endInterval(...)` braid through `finalizeRecording()`. They're useful when reading the pipeline in Instruments. Nobody is reading this pipeline in Instruments — it's a personal app, the developer can `print` and read logs.

### Task A1: Remove signposter usage from `CapturePipeline.finalizeRecording`

**Files:**
- Modify: `voxline/Pipeline/CapturePipeline.swift`
- Modify: `voxline/Diagnostics/AppLog.swift`

- [ ] **Step 1: Confirm baseline build is green**

```bash
xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS,arch=arm64' -quiet 2>&1 | tail -10
```

Expected: `** TEST SUCCEEDED **`. If it fails on `main`, stop and investigate before continuing.

- [ ] **Step 2: Delete every `signposter` line from `finalizeRecording`**

In `voxline/Pipeline/CapturePipeline.swift`:

- Delete the `let signposter = AppLog.pipelineSignposter` / `let sessionID = ...` / `let sessionInterval = ...` block (currently lines 129-131).
- Delete every `signposter.beginInterval(...)` and `signposter.endInterval(...)` call (transcribe, llm, paste, session).
- The final `signposter.endInterval("session", sessionInterval)` before `resetIdle()` goes too.

The method's control flow is unchanged. Result should read as a straight `do/try/catch` sequence with no signposting.

- [ ] **Step 3: Remove the unused symbol from `AppLog`**

In `voxline/Diagnostics/AppLog.swift`, delete this line:

```swift
    static let pipelineSignposter = OSSignposter(subsystem: subsystem, category: "pipeline")
```

`import OSLog` stays — `Logger` is still used.

- [ ] **Step 4: Build + run tests**

```bash
xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS,arch=arm64' -quiet 2>&1 | tail -30
```

Expected: `** TEST SUCCEEDED **`. No test in `voxlineTests/` references `signposter`/`OSSignposter` so this is purely a removal.

- [ ] **Step 5: Commit**

```bash
git add voxline/Pipeline/CapturePipeline.swift voxline/Diagnostics/AppLog.swift
git commit -m "refactor(simplify): strip OSSignposter from CapturePipeline"
```

---

## Pass B — Drop `OSLog` `privacy:` interpolations

**Why:** `privacy: .public` / `.private` matters when logs are exported by users into sysdiagnoses or by Apple's `log` daemon for an App Store app. Voxline is a local personal app the developer reads via `scripts/tail-logs.sh`. Privacy interpolations add ~45 sites of visual noise with no payoff.

### Task B1: Sweep `privacy: .public` and `privacy: .private` out of log strings

**Files:**
- Modify (15 files containing `privacy:`):
  - `voxline/Audio/AudioCaptureService.swift`
  - `voxline/Hotkey/HotkeyMonitor.swift`
  - `voxline/LLM/AnthropicClient.swift`
  - `voxline/LLM/HTTPClient.swift`
  - `voxline/LLM/LLMService.swift`
  - `voxline/LLM/OpenAIClient.swift`
  - `voxline/Modes/ModeStore.swift`
  - `voxline/Output/ClipboardInjector.swift`
  - `voxline/Pipeline/CapturePipeline.swift`
  - `voxline/Storage/AppSettings.swift`
  - `voxline/Storage/DataProtectionKeychain.swift`
  - `voxline/Transcription/TranscriptionService.swift`
  - `voxline/voxlineApp.swift`
  - `voxline/Settings/APIKeysSettingsViewModel.swift`
  - Anything else `grep -rn 'privacy:' voxline/` turns up.

- [ ] **Step 1: Find every occurrence**

```bash
grep -rn 'privacy: \.public\|privacy: \.private' voxline/ | wc -l
```

Expected: ~45 lines across ~15 files.

- [ ] **Step 2: Translate each interpolation to plain interpolation**

For each `AppLog.<cat>.<level>(...)` call:

- `\(value, privacy: .public)` → `\(value)`
- `\(value, privacy: .private)` → `\(value)`

The trailing-comma argument is what makes the call use `OSLogPrivacy`. Removing it leaves the standard string interpolation.

Worked example (from `voxline/Pipeline/CapturePipeline.swift`, line ~111):

Before:
```swift
AppLog.pipeline.info("recording stopped: samples=\(samples.count, privacy: .public) duration=\(self.state.lastRecordingDuration ?? 0, privacy: .public)s peak=\(self.state.lastPeakLevel, privacy: .public)")
```

After:
```swift
AppLog.pipeline.info("recording stopped: samples=\(samples.count) duration=\(self.state.lastRecordingDuration ?? 0)s peak=\(self.state.lastPeakLevel)")
```

Apply mechanically across the file list. Where a previous line worked around the same call to construct a `description:` parameter purely for `privacy:` reasons, simplify back to direct interpolation.

- [ ] **Step 3: Verify no `privacy:` remains in app code**

```bash
grep -rn 'privacy: \.' voxline/
```

Expected: zero lines.

- [ ] **Step 4: Build + run tests**

```bash
xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS,arch=arm64' -quiet 2>&1 | tail -30
```

Expected: `** TEST SUCCEEDED **`. No test asserts log output, so behavior is identical.

- [ ] **Step 5: Commit**

```bash
git add voxline/
git commit -m "refactor(simplify): drop OSLog privacy interpolations"
```

---

## Pass C — Strip historical / spec-pointer comments

**Why:** Multi-paragraph "see Plan N", "removed in Plan 3", "GhostPepper does X", "see docs/superpowers/specs/...", "spec §4.3 step 4" preambles tie the source to a paper trail no future reader needs. The user said functionality is perfect — these comments are archeology, not documentation.

### Task C1: Sweep historical comments

**Files (definite hits):**
- `voxline/Output/ClipboardInjector.swift` — references to "GhostPepper", "spec §4.3", "see docs/superpowers/specs/..."
- `voxline/Output/PasteboardSnapshot.swift` — "see spec §7.1"
- `voxline/Hotkey/HotkeyMonitor.swift` — "spec §4.1 fail-safe"
- `voxline/MenuBar/MenuBarContent.swift` — "TODO: revert — temporarily exposing Debug…"
- `voxline/voxlineApp.swift` — "Plan 2's debug Window scene removed in Plan 3" comment
- `voxline/Pipeline/PipelineProtocols.swift` — "see `docs/superpowers/specs/2026-05-12-vocab-cleanup-only-pivot-design.md`"
- Anywhere else `grep -rn 'GhostPepper\|spec §\|docs/superpowers\|Plan [0-9]\|Plan 4' voxline/` turns up.

**Rule:**
- **Keep:** single-line docstrings explaining what a type/method is; comments warning about a still-relevant macOS / hardware quirk (e.g., "TUIs drop paste when the keystroke arrives too fast"); load-bearing invariants (e.g., "wildcard must stay last").
- **Delete:** any sentence referencing a Plan, spec file, previous version, "previously…", "before Plan N", "as we used to do", commit SHAs, "GhostPepper", "see docs/...".

- [ ] **Step 1: Enumerate hits**

```bash
grep -rn 'GhostPepper\|spec §\|docs/superpowers\|^[[:space:]]*//.*Plan [0-9]\|previously the\|used to\|before Plan' voxline/
```

Read the list. For each line, decide: is this a still-useful invariant comment, or archeology?

- [ ] **Step 2: Edit file-by-file**

Work through the hits and prune the archeology. Where a multi-paragraph block contains both archeology and a useful invariant, keep the invariant as a single sentence and delete the rest.

Worked example — `voxline/Output/ClipboardInjector.swift:62-65`:

Before:
```swift
/// AX value-set and synthetic-typing fallbacks can run instead. Mirrors the
/// pattern GhostPepper uses to avoid stranded synthetic keystrokes in apps
/// that don't actually accept paste.
protocol PasteEligibilityChecking: Sendable {
```

After:
```swift
/// AX value-set and synthetic-typing fallbacks can run instead.
protocol PasteEligibilityChecking: Sendable {
```

Worked example — `voxline/voxlineApp.swift:62-63`:

Before:
```swift
        // Plan 2's debug Window scene removed in Plan 3 — paste replaces the
        // verification UI.
```

After: delete both lines.

Worked example — `voxline/MenuBar/MenuBarContent.swift:47-49`:

Before:
```swift
        // TODO: revert — temporarily exposing Debug in Release builds for
        // field diagnostics. Restore the `#if DEBUG` / `#endif` wrapper
        // around the Divider + Button below before shipping.
```

After: delete (Pass H removes the Debug menu item entirely).

- [ ] **Step 3: Verify the archeology terms are gone**

```bash
grep -rn 'GhostPepper\|docs/superpowers\|spec §\|Plan [0-9]' voxline/
```

Expected: zero lines. (Test files in `voxlineTests/` may still reference Plans; leave them.)

- [ ] **Step 4: Build + run tests**

```bash
xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS,arch=arm64' -quiet 2>&1 | tail -30
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add voxline/
git commit -m "refactor(simplify): strip historical and spec-pointer comments"
```

---

## Pass D — Collapse `AppErrorCategory` into two distinct states

**Why:** The `AppErrorCategory` enum (permissions / pipeline / modelPrep) exists solely so the reconcile loop and `startRecording` know which errors are "theirs" to clear. The matrix is hard to read. Collapse to two semantically named states: `.permissionsError(String)` for sticky permissions failures, `.error(String)` for everything else clearable on retry.

### Task D1: Replace the enum with two AppStatus cases

**Files:**
- Modify: `voxline/AppState.swift`
- Modify: `voxline/Pipeline/CapturePipeline.swift`
- Modify: `voxline/voxlineApp.swift` (AppCoordinator)
- Modify: `voxline/MenuBar/MenuBarContent.swift`
- Modify: `voxline/Debug/DebugView.swift` (will be removed in Pass H — update only if you do Pass H separately)
- Modify: `voxlineTests/CapturePipelineErrorTaxonomyTests.swift`
- Modify: `voxlineTests/AppStateTests.swift` (if it asserts on category)
- Modify: any other test that pattern-matches `.error(category:`

- [ ] **Step 1: Locate every reference**

```bash
grep -rn 'AppErrorCategory\|\.error(category:\|\.error(\.permissions\|\.error(\.pipeline\|\.error(\.modelPrep' voxline/ voxlineTests/
```

Read the list — there are about a dozen call sites in app code and several in tests.

- [ ] **Step 2: Edit `voxline/AppState.swift`**

Replace lines 1-41 with:

```swift
import Foundation
import Observation

enum AppStatus: Equatable {
    case idle
    case recording
    case thinking
    /// First-run model fetch in progress. `progress` is in [0, 1].
    case downloadingModel(progress: Double)
    /// Model files are on disk but Core ML / Apple Neural Engine is still
    /// compiling them. The first run after download can take 30s-2min.
    case preparingModel
    /// Sticky failure that requires the user to act in System Settings.
    /// Cleared by AppCoordinator's reconcile loop when permissions return.
    case permissionsError(String)
    /// Transient failure (audio, transcription, LLM, paste, model prep).
    /// Cleared by the next user action — chord press or successful model prep.
    case error(String)

    var blocksRecording: Bool {
        switch self {
        case .downloadingModel, .preparingModel: return true
        default: return false
        }
    }
}
```

Delete the `AppErrorCategory` enum entirely.

- [ ] **Step 3: Edit `voxline/Pipeline/CapturePipeline.swift`**

In the `setError` private function (currently lines 230-234), replace:

```swift
private func setError(_ message: String, category: AppErrorCategory = .pipeline) {
    state.status = .error(category: category, message: message)
    state.recordingStartedAt = nil
    state.audioLevel = 0
}
```

with:

```swift
private func setError(_ message: String, permissions: Bool = false) {
    state.status = permissions ? .permissionsError(message) : .error(message)
    state.recordingStartedAt = nil
    state.audioLevel = 0
}
```

In the paste catch block (currently lines 207-212), replace:

```swift
} catch let e as TextInsertionError {
    ...
    let category: AppErrorCategory = (e == .accessibilityNotGranted) ? .permissions : .pipeline
    AppLog.paste.error("inject failed: \(e.errorDescription ?? "unknown")")
    return setError(e.errorDescription ?? "Text insertion failed.", category: category)
}
```

with:

```swift
} catch let e as TextInsertionError {
    ...
    AppLog.paste.error("inject failed: \(e.errorDescription ?? "unknown")")
    return setError(e.errorDescription ?? "Text insertion failed.", permissions: e == .accessibilityNotGranted)
}
```

In `startRecording` (currently lines 66-73), replace:

```swift
switch state.status {
case .recording, .thinking, .downloadingModel, .preparingModel:
    return
case .error(.permissions, _):
    return
case .idle, .error:
    break
}
```

with:

```swift
switch state.status {
case .recording, .thinking, .downloadingModel, .preparingModel, .permissionsError:
    return
case .idle, .error:
    break
}
```

- [ ] **Step 4: Edit `voxline/voxlineApp.swift` (AppCoordinator)**

In `installHotkey` (currently line 306), replace:

```swift
state.status = .error(category: .permissions, message: "Hotkey monitoring requires Accessibility permission…")
```

with:

```swift
state.status = .permissionsError("Hotkey monitoring requires Accessibility permission. Grant it in System Settings → Privacy & Security — Voxline will pick it up automatically.")
```

In `reconcileTapWithPermissionsAndEnabled` (currently lines 352-355 and 363-365), replace:

```swift
if case .error(.permissions, _) = state.status {
    state.status = .idle
}
```

with:

```swift
if case .permissionsError = state.status {
    state.status = .idle
}
```

And:

```swift
if state.hotkeyEnabled && !permissionsOK {
    state.status = .error(category: .permissions, message: "Accessibility permission was revoked…")
}
```

with:

```swift
if state.hotkeyEnabled && !permissionsOK {
    state.status = .permissionsError("Accessibility permission was revoked. Re-grant it in System Settings → Privacy & Security; Voxline will recover automatically.")
}
```

In `runModelPrepTask` (currently line 469), replace:

```swift
state.status = .error(category: .modelPrep, message: "Model setup failed: \(error.localizedDescription). Try Retry or relaunch Voxline.")
```

with:

```swift
state.status = .error("Model setup failed: \(error.localizedDescription). Try Retry or relaunch Voxline.")
```

- [ ] **Step 5: Edit `voxline/MenuBar/MenuBarContent.swift`**

Currently line 15:

```swift
if case .error(_, let message) = state.status {
```

Replace with a pattern that matches either error case:

```swift
if let message = state.status.errorMessage {
```

And add a computed accessor to `AppStatus` in `AppState.swift`:

```swift
extension AppStatus {
    /// Non-nil iff status is `.error` or `.permissionsError`. Used by the
    /// menu bar's error banner.
    var errorMessage: String? {
        switch self {
        case .error(let m), .permissionsError(let m): return m
        default: return nil
        }
    }
}
```

- [ ] **Step 6: Update `voxlineTests/CapturePipelineErrorTaxonomyTests.swift`**

Every assertion shaped like:

```swift
guard case .error(let category, let msg) = state.status else { ... }
#expect(category == .pipeline)
```

becomes:

```swift
guard case .error(let msg) = state.status else { ... }
```

And the permissions case:

```swift
guard case .error(let category, let msg) = state.status else { ... }
#expect(category == .permissions)
```

becomes:

```swift
guard case .permissionsError(let msg) = state.status else { ... }
```

Specifically rewrite:
- `missing_api_key_surfaces_actionable_error` — drop the `category == .pipeline` line; pattern-match on `.error(let msg)`.
- `revoked_accessibility_during_paste_is_sticky_permissions_error` — pattern-match on `.permissionsError(let msg)`.
- Any other `category ==` assertion in the file.

- [ ] **Step 7: Update other tests that match the old enum**

```bash
grep -rn 'AppErrorCategory\|\.error(category:\|\.error(\.permissions\|\.error(\.pipeline\|\.error(\.modelPrep' voxlineTests/
```

For each hit, mirror the rewrites above. Likely files: `AppStateTests.swift`, `MenuBarIconTests.swift`, `CapturePipelineTests.swift`.

For `MenuBarIconTests.swift` specifically, the `iconForError` test should now construct `.error("msg")` rather than `.error(category:.pipeline, message:)`.

- [ ] **Step 8: Verify nothing references the deleted enum**

```bash
grep -rn 'AppErrorCategory' voxline/ voxlineTests/
```

Expected: zero lines.

- [ ] **Step 9: Build + run tests**

```bash
xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS,arch=arm64' -quiet 2>&1 | tail -30
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 10: Commit**

```bash
git add voxline/ voxlineTests/
git commit -m "refactor(simplify): collapse AppErrorCategory into permissionsError vs error"
```

---

## Pass E — Replace `WindowVisibilityCoordinator` with a minimal dock-policy switch

**Why:** 150 LOC + a 5-attempt polling tagger to flip `NSApp.activationPolicy` between `.regular` and `.accessory` based on titled-window count. Voxline has at most four titled windows (Settings, About, History, ModelDownload), all opened explicitly. The whole framework collapses to "observe `didBecomeKey` / `willClose` for any titled window, count them."

### Task E1: Drop the coordinator down to ~40 lines

**Files:**
- Modify: `voxline/MenuBar/WindowVisibilityCoordinator.swift`
- Modify: `voxline/voxlineApp.swift` (`tagSettingsWindowSoon` call site)
- Modify: `voxline/UI/AboutWindowController.swift` (uses the identifier)
- Modify: `voxline/UI/HistoryWindowController.swift` (uses the identifier)
- Modify: `voxline/Debug/DebugView.swift` (uses the identifier — will be deleted in Pass H, but update here for safety if H runs later)
- Modify: `voxline/Wizard/FirstRunWindowController.swift` (uses the identifier)
- Delete from test suite: `voxlineTests/WindowVisibilityCoordinatorTests.swift`

- [ ] **Step 1: Locate every reference to the identifier and to `tagSettingsWindow`**

```bash
grep -rn 'WindowVisibilityCoordinator\|dockworthyIdentifier\|tagSettingsWindow' voxline/ voxlineTests/
```

- [ ] **Step 2: Replace `voxline/MenuBar/WindowVisibilityCoordinator.swift`**

Replace the entire file contents with:

```swift
import AppKit

/// Flips the app between `.regular` (Dock icon visible) and `.accessory`
/// (menu-bar only) based on whether any titled window is currently visible.
/// HUD windows (recording pill, model download) are borderless and are
/// excluded automatically by the `.titled` style-mask check.
@MainActor
final class WindowVisibilityCoordinator {
    private let center: NotificationCenter
    private var observers: [NSObjectProtocol] = []
    private var tracked: Set<ObjectIdentifier> = []

    init(center: NotificationCenter = .default) {
        self.center = center
    }

    func start() {
        for w in NSApp.windows where isTitled(w) && w.isVisible {
            tracked.insert(ObjectIdentifier(w))
        }
        reconcile()

        let key = center.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let w = note.object as? NSWindow, self.isTitled(w) else { return }
                self.tracked.insert(ObjectIdentifier(w))
                self.reconcile()
            }
        }
        let close = center.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let w = note.object as? NSWindow else { return }
                self.tracked.remove(ObjectIdentifier(w))
                self.reconcile()
            }
        }
        observers = [key, close]
    }

    private func isTitled(_ w: NSWindow) -> Bool {
        w.styleMask.contains(.titled)
    }

    private func reconcile() {
        let policy: NSApplication.ActivationPolicy = tracked.isEmpty ? .accessory : .regular
        // Defer to next runloop tick when going .accessory so a closing
        // window has time to finish ordering out before AppKit re-evaluates
        // the Dock state (avoids a stuck Dock icon).
        if policy == .accessory {
            DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
        } else {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
        }
    }

    deinit {
        for o in observers { center.removeObserver(o) }
    }
}
```

- [ ] **Step 3: Remove the `tagSettingsWindowSoon` plumbing from `voxlineApp.swift`**

In `voxline/voxlineApp.swift`:

- Delete the `tagSettingsWindow: { delegate.tagSettingsWindowSoon() }` argument to `MenuBarContent` (around line 47).
- Delete the `func tagSettingsWindowSoon()` method on `AppDelegate` (lines 97-99).

In `voxline/MenuBar/MenuBarContent.swift`:

- Delete the `var tagSettingsWindow: () -> Void = {}` property.
- Delete the `tagSettingsWindow()` call inside the Settings button action.

- [ ] **Step 4: Remove `.identifier = WindowVisibilityCoordinator.dockworthyIdentifier` lines**

Each window controller (`AboutWindowController`, `HistoryWindowController`, `DebugWindowController`, `FirstRunWindowController`, `ModelDownloadWindow`) currently sets `.identifier = WindowVisibilityCoordinator.dockworthyIdentifier`. The new coordinator does not use identifiers — it matches on `styleMask.contains(.titled)`.

Delete every `w.identifier = WindowVisibilityCoordinator.dockworthyIdentifier` line and any `.identifier = ...` line that was added solely for this purpose.

- [ ] **Step 5: Delete `voxlineTests/WindowVisibilityCoordinatorTests.swift`**

```bash
git rm voxlineTests/WindowVisibilityCoordinatorTests.swift
```

This test exercised the now-deleted tagging logic. The new coordinator is small enough not to need unit coverage; manual verification via `make Settings/About/History open → Dock icon appears; close all → Dock icon disappears` covers it.

- [ ] **Step 6: Confirm references to the deleted symbols are gone**

```bash
grep -rn 'dockworthyIdentifier\|tagSettingsWindowAfterOpen\|tagSettingsWindowSoon\|ActivationPolicySetter' voxline/ voxlineTests/
```

Expected: zero lines.

- [ ] **Step 7: Build + run tests**

```bash
xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS,arch=arm64' -quiet 2>&1 | tail -30
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 8: Manual smoke check**

Build and launch the app. Verify:
- Menu-bar only at launch (no Dock icon).
- Open Settings → Dock icon appears.
- Close Settings → Dock icon disappears.
- Open About / History → Dock icon appears.

- [ ] **Step 9: Commit**

```bash
git add voxline/ voxlineTests/
git rm voxlineTests/WindowVisibilityCoordinatorTests.swift 2>/dev/null || true
git commit -m "refactor(simplify): replace WindowVisibilityCoordinator with minimal style-mask coordinator"
```

---

## Pass F — Trim `ClipboardInjector`'s 8 dependency-injection protocols

**Why:** `ClipboardInjector` defines 8 protocols (`ModifierGate`, `KeyEventPosting`, `PasteKeyResolving`, `TextTyping`, `PasteboardSnapshotting`, `AccessibilityTrustChecking`, `PasteEligibilityChecking`, `FocusedTextSystem`) purely to enable test doubles. Many of these have a single production implementation and a single test fake. Collapse the ones that aren't worth their weight.

**Decision rules:**
- **Keep `FocusedTextSystem`** — the AX queries here have meaningful logic (selection-range arithmetic, secure-field detection) that's worth testing in isolation.
- **Keep `PasteboardSnapshotting`** — tests need to force snapshot failure to drive the fallback chain; faking `NSPasteboard` end-to-end is awkward.
- **Keep `PasteEligibilityChecking`** — tests need to control eligibility independently of menu-bar AX state.
- **Inline `ModifierGate`, `KeyEventPosting`, `PasteKeyResolving`, `TextTyping`, `AccessibilityTrustChecking`** — these wrap a single CGEvent / TIS / AX call each. Tests that need to verify "Cmd+V was posted" can do so by spying on a single closure parameter on the injector itself, rather than via a whole protocol type.

### Task F1: Replace five wrap-protocols with closure parameters

**Files:**
- Modify: `voxline/Output/ClipboardInjector.swift`
- Modify: `voxline/voxlineApp.swift` (call site that constructs the injector)
- Modify: `voxlineTests/ClipboardInjectorTests.swift`

- [ ] **Step 1: Survey the test fakes**

```bash
grep -n 'FakeModifierGate\|FakeKeyPoster\|FakePasteKeyResolver\|FakeTextTyper\|StubAccessibilityTrust\|ThrowingSnapshotter' voxlineTests/ClipboardInjectorTests.swift
```

This shows which protocols each test relies on. Confirm `FocusedTextSystem`, `PasteboardSnapshotting`, and `PasteEligibilityChecking` are the ones that genuinely vary across tests, while the others are nearly always the same default fake.

- [ ] **Step 2: Replace the five wrap-protocols with closures on `ClipboardInjector`**

In `voxline/Output/ClipboardInjector.swift`:

- Delete the `protocol ModifierGate`, `protocol KeyEventPosting`, `protocol PasteKeyResolving`, `protocol TextTyping`, `protocol AccessibilityTrustChecking` declarations.
- Delete the structs `CGEventModifierGate`, `CGEventKeyPoster`, `CurrentKeyboardLayoutPasteKeyResolver`, `CGEventTextTyper`, `SystemAccessibilityTrust`. Move their implementation bodies into private helper functions or closures on `ClipboardInjector` itself.

The new `ClipboardInjector` initializer looks like:

```swift
init(
    pasteboard: NSPasteboard = .general,
    focusedTextSystem: FocusedTextSystem = AXFocusedTextSystem(),
    snapshotter: PasteboardSnapshotting = DefaultPasteboardSnapshotter(),
    pasteEligibility: PasteEligibilityChecking = AlwaysPasteEligible(),
    chordIsHeld: @escaping @Sendable () -> Bool = ClipboardInjector.defaultChordIsHeld,
    forceClearChord: @escaping @Sendable () -> Void = ClipboardInjector.defaultForceClearChord,
    postKey: @escaping @Sendable (CGKeyCode, CGEventFlags) -> Void = ClipboardInjector.defaultPostKey,
    pasteVirtualKeyCode: @escaping @Sendable () -> CGKeyCode = ClipboardInjector.defaultPasteKey,
    typeText: @escaping @Sendable (String) throws -> Void = ClipboardInjector.defaultTypeText,
    isAccessibilityTrusted: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() },
    chordReleaseTimeout: Duration = .seconds(1),
    chordPollInterval: Duration = .milliseconds(15),
    pasteWriteSettleDelay: Duration = .milliseconds(50),
    restoreDelay: Duration = .milliseconds(300),
    verificationDelay: Duration = .milliseconds(150)
) { ... }
```

Where the `defaultChordIsHeld` / `defaultForceClearChord` / `defaultPostKey` / `defaultPasteKey` / `defaultTypeText` are `static func` members carrying the body of each former impl-struct. (Move the bodies verbatim — there is no logic change.)

The instance properties `modifierGate`, `keyPoster`, `pasteKeyResolver`, `textTyper`, `accessibilityTrust` become the equivalent closure properties:

```swift
let chordIsHeld: @Sendable () -> Bool
let forceClearChord: @Sendable () -> Void
let postKey: @Sendable (CGKeyCode, CGEventFlags) -> Void
let pasteVirtualKeyCode: @Sendable () -> CGKeyCode
let typeText: @Sendable (String) throws -> Void
let isAccessibilityTrusted: @Sendable () -> Bool
```

Call sites inside `ClipboardInjector` change accordingly:
- `modifierGate.chordIsHeld()` → `chordIsHeld()`
- `keyPoster.postKey(...)` → `postKey(...)`
- etc.

- [ ] **Step 3: Update the production call site**

In `voxline/voxlineApp.swift`'s `buildServices` (lines 213-217), the constructor call:

```swift
let injector = ClipboardInjector(
    focusedTextSystem: focusedTextSystem,
    pasteEligibility: DefaultPasteEligibility(focusedTextSystem: focusedTextSystem)
)
```

stays unchanged — all the removed parameters keep their defaults.

- [ ] **Step 4: Update `voxlineTests/ClipboardInjectorTests.swift`**

Replace the fake classes with closures. The test:

```swift
let gate = FakeModifierGate()
let poster = FakeKeyPoster()
let injector = await ClipboardInjector(
    pasteboard: board,
    modifierGate: gate,
    keyPoster: poster,
    pasteKeyResolver: FakePasteKeyResolver(keyCode: 9),
    focusedTextSystem: focused,
    textTyper: FakeTextTyper(),
    accessibilityTrust: StubAccessibilityTrust(trusted: true),
    restoreDelay: .milliseconds(20)
)
let outcome = try await injector.inject("CLEAN")
#expect(poster.posted.count == 1)
#expect(poster.posted[0].keyCode == 9)
#expect(poster.posted[0].flags == [.maskCommand])
```

becomes:

```swift
let posted = LockedBox<[(CGKeyCode, CGEventFlags)]>([])
let injector = await ClipboardInjector(
    pasteboard: board,
    focusedTextSystem: focused,
    chordIsHeld: { false },
    forceClearChord: {},
    postKey: { code, flags in posted.append((code, flags)) },
    pasteVirtualKeyCode: { 9 },
    typeText: { _ in },
    isAccessibilityTrusted: { true },
    restoreDelay: .milliseconds(20)
)
let outcome = try await injector.inject("CLEAN")
let snapshot = posted.read()
#expect(snapshot.count == 1)
#expect(snapshot[0].0 == 9)
#expect(snapshot[0].1 == [.maskCommand])
```

`LockedBox` is a tiny local helper at the top of the test file:

```swift
final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ initial: T) { self.value = initial }
    func read() -> T { lock.lock(); defer { lock.unlock() }; return value }
    func write(_ new: T) { lock.lock(); value = new; lock.unlock() }
}
extension LockedBox where T == [(CGKeyCode, CGEventFlags)] {
    func append(_ item: (CGKeyCode, CGEventFlags)) {
        lock.lock(); value.append(item); lock.unlock()
    }
}
```

(Place it once at the top of `ClipboardInjectorTests.swift`. The boxing pattern replaces `final class FakeKeyPoster: @unchecked Sendable`.)

Apply the same rewrite mechanically to every test in the file: replace `FakeModifierGate` / `FakeKeyPoster` / `FakePasteKeyResolver` / `FakeTextTyper` / `StubAccessibilityTrust` with inline closures, using `LockedBox` only when a test reads back what was captured.

- [ ] **Step 5: Verify no test still references the deleted protocols / fakes**

```bash
grep -n 'FakeModifierGate\|FakeKeyPoster\|FakePasteKeyResolver\|FakeTextTyper\|StubAccessibilityTrust\|ModifierGate\b\|KeyEventPosting\|PasteKeyResolving\|TextTyping\b\|AccessibilityTrustChecking' voxlineTests/ClipboardInjectorTests.swift
```

Expected: zero hits.

- [ ] **Step 6: Build + run tests**

```bash
xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS,arch=arm64' -quiet 2>&1 | tail -30
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
git add voxline/Output/ClipboardInjector.swift voxline/voxlineApp.swift voxlineTests/ClipboardInjectorTests.swift
git commit -m "refactor(simplify): collapse 5 ClipboardInjector protocols into closure params"
```

---

## Pass G — Collapse `KeychainStorage`, `HTTPClient`, `PipelineProtocols` test seams

**Why:** Three test-only abstractions, each with a single production impl and a single test fake:
- `KeychainStorage` protocol → `DataProtectionKeychain` (prod) + `InMemoryKeychain` (tests).
- `HTTPClient` protocol → `URLSessionHTTPClient` (prod) + test fakes.
- `PipelineProtocols.swift` declares 7 interfaces (`AudioCapturing`, `Transcribing`, `ModeResolving`, `FocusedFieldInspecting`, `LLMServing`, `ClipboardInjecting`, `FrontmostAppProviding`) — each has one prod type that conforms via `extension X: Y {}`.

For `HTTPClient`: keep the seam — testing the HTTP-shaped behavior of `AnthropicClient` and `OpenAIClient` without a real network is genuinely valuable. **No change.**

For `KeychainStorage`: keep, but inline the in-memory fake into a single test helper file — done already. **No change beyond a comment cleanup.**

For `PipelineProtocols`: keep most of these — the `CapturePipeline` tests drive every error path through fake injection of these types. **No change.**

After this audit the conclusion is: **Pass G is no-op for the protocols themselves.** What remains worth pruning are dangling extension files and the comment claims that there are "two impls" when one is test-only.

Actually, do prune:
- `LegacyKeychain` / migrator scaffolding — already deleted in commit `244cddf` ("delete legacy keychain scaffolding post-migration"). Verify nothing lingering.
- `KeychainStorage`'s docstring still says "Two impls live behind this" — update to acknowledge `InMemoryKeychain` is test-only.

### Task G1: Audit and document the protocol seams

**Files:**
- Modify: `voxline/Storage/KeychainStorage.swift`
- Modify: `voxline/LLM/HTTPClient.swift`
- Modify: `voxline/Pipeline/PipelineProtocols.swift`

- [ ] **Step 1: Confirm no legacy keychain scaffolding remains**

```bash
grep -rn 'LegacyKeychain\|KeychainMigrator\|probeAndFallback\|fallbackKeychain' voxline/ voxlineTests/
```

Expected: zero. If anything turns up, delete it.

- [ ] **Step 2: Clean up `KeychainStorage.swift` docstring**

Replace the docstring header (currently lines 3-7) with:

```swift
/// Generic-password keychain abstraction. `DataProtectionKeychain` is the
/// only production impl; tests inject `InMemoryKeychain` from `voxlineTests/`.
///
/// `account` is the per-record name (e.g. "anthropic", "openai"); the service
/// id is fixed at the implementation layer and never crosses this boundary.
```

- [ ] **Step 3: Confirm `HTTPClient` and `PipelineProtocols` need no changes**

Read both files. Verify each protocol is used by at least one test as a fake — if so, leave it. Today's grep shows yes for all 7 in PipelineProtocols (`CapturePipelineTests.swift` and `CapturePipelineErrorTaxonomyTests.swift` define fakes for each).

If any protocol's tests have all been deleted by an earlier pass, delete it now. Run:

```bash
for p in AudioCapturing Transcribing ModeResolving FocusedFieldInspecting LLMServing ClipboardInjecting FrontmostAppProviding; do
  echo "== $p =="
  grep -l "Fake.*: $p\|: $p," voxlineTests/
done
```

Any protocol with zero matching test files is dead weight — delete it from `PipelineProtocols.swift` and the corresponding `extension X: Y {}` line.

- [ ] **Step 4: Build + run tests**

```bash
xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS,arch=arm64' -quiet 2>&1 | tail -30
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add voxline/Storage/KeychainStorage.swift voxline/LLM/HTTPClient.swift voxline/Pipeline/PipelineProtocols.swift
git commit -m "refactor(simplify): tighten keychain docstring; audit pipeline protocol seams"
```

---

## Pass H — Delete the Debug window

**Why:** The Debug window is a 436-LOC SwiftUI view that mirrors 8 `debug*` fields from `AppState`, exposes test buttons (Force-finalize / Reinstall tap / Test paste / Test LLM / Test transcribe / View modes), and ships a 100-LOC modes viewer sheet. For a personal Mac app where the developer can read logs via `scripts/tail-logs.sh` and rebuild with a `print()`, the window is pure overhead. The error banner already surfaces "what just broke." Pass H removes the window, the menu item, the 8 debug fields, and every writer that fed them.

### Task H1: Remove all Debug plumbing

**Files:**
- Delete: `voxline/Debug/DebugView.swift`
- Modify: `voxline/AppState.swift`
- Modify: `voxline/voxlineApp.swift`
- Modify: `voxline/MenuBar/MenuBarContent.swift`
- Modify: `voxline/Hotkey/HotkeyMonitor.swift`
- Modify: `voxline/Pipeline/CapturePipeline.swift`
- Modify: `voxline/AppCoordinator` (inside `voxlineApp.swift`)

- [ ] **Step 1: Locate every reference to `debug*` fields and the window**

```bash
grep -rn 'debugHotkeyState\|debugTapInstalled\|debugLastInsertionResult\|debugMicrophoneStatus\|debugAccessibilityStatus\|debugInputMonitoringStatus\|debugLastTestResult\|debugLastFinalizeReason\|DebugWindowController\|DebugView\|openDebugWindow\|onDebugStateChanged\|onDebugFinalizeReason' voxline/ voxlineTests/
```

This is the complete demolition list.

- [ ] **Step 2: Delete `voxline/Debug/DebugView.swift`**

```bash
git rm voxline/Debug/DebugView.swift
```

If the `voxline/Debug/` directory becomes empty, leave it for the build system to handle — Xcode will pick up the deletion via the file system synchronization on next build.

- [ ] **Step 3: Strip the 8 debug fields from `voxline/AppState.swift`**

Delete every property from `// MARK: - Debug diagnostics` to the end of the class:

```swift
// MARK: - Debug diagnostics (rendered in the Debug window)
var debugHotkeyState: String = "idle"
var debugTapInstalled: Bool = false
var debugLastInsertionResult: String = "(none yet)"
var debugMicrophoneStatus: String = "?"
var debugAccessibilityStatus: String = "?"
var debugInputMonitoringStatus: String = "?"
var debugLastTestResult: String = ""
var debugLastFinalizeReason: String = "(none yet)"
```

After deletion, the class ends after `lastCleanupDuration`.

- [ ] **Step 4: Remove the menu item and parameter from `MenuBarContent.swift`**

Delete:

```swift
var openDebugWindow: () -> Void = {}
```

and:

```swift
Divider()
Button("Debug…") { openDebugWindow() }
```

- [ ] **Step 5: Remove debug-window plumbing from `voxlineApp.swift`**

- Delete the `openDebugWindow:` argument passed to `MenuBarContent` (currently lines 31-36).
- Delete the property `let debugWindow = DebugWindowController()` from `AppDelegate`.
- (The `--reset-keys` block stays — it is separate.)

- [ ] **Step 6: Remove debug writers from `HotkeyMonitor.swift`**

Delete:

```swift
var onDebugStateChanged: ((HotkeyStateMachine.State, Bool) -> Void)?
var onDebugFinalizeReason: ((String) -> Void)?
```

And every call site of these:

- In `start()`: delete `onDebugStateChanged?(machine.state, true)` (currently line 64).
- In `feed(_:)`: delete the `onDebugFinalizeReason?(reasonLabel(for: input))` block and the `onDebugStateChanged?(machine.state, eventTap != nil)` line at the end.
- Delete the `reasonLabel(for:)` helper — it has no remaining caller.

`AppLog.hotkey.info("monitor installed")` etc. stay; only the in-process callbacks are gone.

- [ ] **Step 7: Remove debug writers from `CapturePipeline.swift`**

In `finalizeRecording`, delete:

```swift
state.debugLastInsertionResult = outcome.description
```

(currently around line 204).

- [ ] **Step 8: Remove debug writers from `AppCoordinator`**

In `voxline/voxlineApp.swift`, inside `installHotkey`:

- Delete the `monitor.onDebugStateChanged = { ... }` and `monitor.onDebugFinalizeReason = { ... }` blocks.

In `reconcileTapWithPermissionsAndEnabled`:

- Delete the three lines:
  ```swift
  state.debugAccessibilityStatus = String(describing: ax)
  state.debugInputMonitoringStatus = String(describing: im)
  state.debugMicrophoneStatus = String(describing: mic)
  ```
  ...and the now-unused `let im = perms.inputMonitoringStatus`, `let mic = perms.microphoneStatus` reads (keep `let ax = perms.accessibilityStatus` since it's the gate).

- [ ] **Step 9: Verify nothing references the deleted symbols**

```bash
grep -rn 'debugHotkeyState\|debugTapInstalled\|debugLastInsertionResult\|debugMicrophoneStatus\|debugAccessibilityStatus\|debugInputMonitoringStatus\|debugLastTestResult\|debugLastFinalizeReason\|DebugWindowController\|DebugView\|openDebugWindow\|onDebugStateChanged\|onDebugFinalizeReason' voxline/
```

Expected: zero.

```bash
grep -rn 'debugHotkeyState\|debugTapInstalled\|debugLastInsertionResult\|debugMicrophoneStatus\|debugAccessibilityStatus\|debugInputMonitoringStatus\|debugLastTestResult\|debugLastFinalizeReason' voxlineTests/
```

If any test references these, delete the failing test (it tests scaffolding that no longer exists).

- [ ] **Step 10: Build + run tests**

```bash
xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS,arch=arm64' -quiet 2>&1 | tail -30
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 11: Manual smoke check**

Launch the app:
- Menu bar has no "Debug…" entry.
- Hotkey dictation still works.
- An error banner still appears in the menu-bar dropdown when something fails.

- [ ] **Step 12: Commit**

```bash
git add voxline/ voxlineTests/
git rm voxline/Debug/DebugView.swift 2>/dev/null || true
git commit -m "refactor(simplify): delete Debug window and 8 debug state fields"
```

---

## Pass I — Prune trivial tests and concurrency annotations

**Why:** 56 test files / 4,330 LOC against 7,309 LOC of source. Many tests cover trivial constants or DI shims that the earlier passes have already pruned. `@unchecked Sendable` + scattered `MainActor.assumeIsolated` blocks are belt-and-suspenders concurrency annotations against a future Swift 6 mode that isn't enabled (project uses `SWIFT_VERSION = 5.0`).

### Task I1: Delete trivial test files

**Files:**
- Delete: `voxlineTests/MenuBarIconTests.swift` — tests an SF Symbol name lookup; ~8 cases each asserting a string equality.
- Delete: `voxlineTests/SupportLinksTests.swift` — tests URL strings.
- Delete: `voxlineTests/AppPathsTests.swift` — tests path constants.
- Delete: `voxlineTests/InMemoryKeychain.swift` + `voxlineTests/InMemoryKeychainTests.swift` only if no remaining test file uses `InMemoryKeychain`. (Run grep first; if `LLMServiceTests` / `APIKeysSettingsViewModelTests` / `WizardViewModelTests` / `SettingsStatusViewModelTests` still use it, keep both.)

- [ ] **Step 1: Delete the three definite-trivial files**

```bash
git rm voxlineTests/MenuBarIconTests.swift voxlineTests/SupportLinksTests.swift voxlineTests/AppPathsTests.swift
```

- [ ] **Step 2: Check whether `InMemoryKeychain` is still used**

```bash
grep -rln 'InMemoryKeychain' voxlineTests/
```

If only `InMemoryKeychainTests.swift` references it, also delete:

```bash
git rm voxlineTests/InMemoryKeychain.swift voxlineTests/InMemoryKeychainTests.swift
```

Otherwise leave both — they're load-bearing.

- [ ] **Step 3: Build + run tests**

```bash
xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS,arch=arm64' -quiet 2>&1 | tail -30
```

Expected: `** TEST SUCCEEDED **`. Test count drops.

- [ ] **Step 4: Commit**

```bash
git commit -m "refactor(simplify): delete trivial constant-lookup tests"
```

### Task I2: Drop gratuitous `@unchecked Sendable` and `MainActor.assumeIsolated`

**Files:**
- Modify: `voxline/Storage/AppSettings.swift`
- Modify: `voxline/Storage/CustomVocabularyStore.swift`
- Modify: `voxline/Hotkey/HotkeyMonitor.swift`
- Modify: `voxline/MenuBar/WindowVisibilityCoordinator.swift` (the version produced by Pass E)
- Modify: `voxline/voxlineApp.swift` (AppCoordinator timer callback)

- [ ] **Step 1: Audit `@unchecked Sendable` annotations**

```bash
grep -n '@unchecked Sendable' voxline/
```

For each hit:

- `AppSettings`, `CustomVocabularyStore` — these don't actually cross actor boundaries. They're constructed and consumed on the main actor (Settings UI, AppCoordinator). Drop `@unchecked Sendable` and replace `struct X: @unchecked Sendable {` with `struct X {`.

- [ ] **Step 2: Update `AppSettings.swift`**

Replace:

```swift
struct AppSettings: @unchecked Sendable {
```

with:

```swift
struct AppSettings {
```

Drop the multi-paragraph "UserDefaults isn't formally Sendable…" comment block above it. The new struct gets a one-line docstring: `/// Thin wrapper around UserDefaults for non-secret user preferences.`

- [ ] **Step 3: Update `CustomVocabularyStore.swift`**

Same edit:

```swift
struct CustomVocabularyStore: @unchecked Sendable {
```

becomes:

```swift
struct CustomVocabularyStore {
```

Trim the docstring above to one line.

- [ ] **Step 4: Audit `MainActor.assumeIsolated` blocks**

```bash
grep -n 'MainActor\.assumeIsolated' voxline/
```

Today's hits:
- `voxline/Hotkey/HotkeyMonitor.swift` — inside the `tapCallback` C function. **KEEP** — the C callback fires on the main thread but is not Swift-isolated, so `assumeIsolated` is the documented bridge.
- `voxline/voxlineApp.swift` — inside the `Timer.scheduledTimer` closure. **KEEP** — same reason; the Timer callback is not Swift-isolated.
- `voxline/MenuBar/WindowVisibilityCoordinator.swift` — inside `NotificationCenter.addObserver` closures. **KEEP** — same reason.

These are load-bearing for thread safety. **No change in this step.**

- [ ] **Step 5: Audit Sendable closure annotations**

The new `ClipboardInjector` initializer from Pass F uses `@Sendable` closures. Build will tell you if any cause friction. Leave them in for now — they don't add visible noise and may protect against future concurrency mistakes.

- [ ] **Step 6: Build + run tests**

```bash
xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS,arch=arm64' -quiet 2>&1 | tail -30
```

Expected: `** TEST SUCCEEDED **`. If Swift complains about Sendable conformance for `AppSettings` or `CustomVocabularyStore` in a specific use site (e.g., being captured by an `@escaping` closure crossing isolation), re-add `@unchecked Sendable` only for that struct, with a one-line comment naming the call site.

- [ ] **Step 7: Commit**

```bash
git add voxline/Storage/AppSettings.swift voxline/Storage/CustomVocabularyStore.swift
git commit -m "refactor(simplify): drop unchecked Sendable on AppSettings and CustomVocabularyStore"
```

### Task I3: Final sweep

- [ ] **Step 1: Diff against `main` of nine commits ago**

```bash
git diff --stat HEAD~9 -- voxline/ voxlineTests/ | tail -5
```

Expected: net negative line count of several hundred lines across both directories.

- [ ] **Step 2: Final full-suite run**

```bash
xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS,arch=arm64' -quiet 2>&1 | tail -30
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 3: Manual end-to-end smoke test**

Launch the built app:
- Hold the hotkey, speak a sentence, release.
- Confirm the cleaned text appears in the focused app (your editor / a Terminal / Slack).
- Open Settings → close → Dock icon disappears.
- Toggle "Pause Voxline" in the menu bar → confirm hotkey is inert → toggle back.
- Open About → close.

If any of these break, bisect across the nine commits.

---

## Self-Review notes

**Spec coverage:** Each of the user's nine simplification asks (Pass A through I, skipping #9 wizard) has a dedicated task block:

| Pass | Original review item |
|---|---|
| A | #1 Strip OSSignposter |
| B | #2 Drop privacy interpolations |
| C | #6 Strip historical comments |
| D | #5 Replace AppErrorCategory |
| E | #8 Collapse WindowVisibilityCoordinator |
| F | #4 Trim ClipboardInjector protocols |
| G | #3 Audit KeychainStorage / HTTPClient / PipelineProtocols (verdict: keep most; clean docstrings) |
| H | #7 DebugView decision (verdict: delete) |
| I | #10 Trivial tests + concurrency annotations |

**Ordering rationale:** Mechanical/scoped passes (A, B, C) first — low blast radius, build the cleanup muscle. Domain refactors (D, E) next — small surface, clear payoff. Larger refactors (F) and audits (G) in the middle. Aggressive deletes (H) last before test pruning (I), so the test diff in Pass I reflects everything that's already been removed.

**No placeholders:** Every step shows the actual code to write or delete, every command is runnable, every grep target is concrete.

**Type consistency:**
- `AppStatus.permissionsError(String)` / `.error(String)` introduced in Pass D, referenced consistently in D's later steps and unchanged through the rest of the plan.
- `ClipboardInjector` closure parameter names (`chordIsHeld`, `forceClearChord`, `postKey`, `pasteVirtualKeyCode`, `typeText`, `isAccessibilityTrusted`) are used identically in Task F1 Steps 2-4.
- `WindowVisibilityCoordinator.start()` is the only public method called in Pass E and matches the call site in `voxlineApp.swift:applicationDidFinishLaunching`.
