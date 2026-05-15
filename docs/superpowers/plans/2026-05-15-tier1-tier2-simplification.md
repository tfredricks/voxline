# Tier 1 + Tier 2 Simplification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Apply the Tier 1 and Tier 2 simplification candidates from the 2026-05-15 review without changing user-visible behavior.

**Architecture:** Pure refactor pass. No new features, no API surface changes beyond internal seams. Each task is independent, committed separately so any single task can be rolled back without affecting the others.

**Tech Stack:** Swift, macOS app, Xcode project. Tests use Swift Testing (`@Suite`, `@Test`, `#expect`).

**Build/test command (used in every "run tests" step):**

```bash
xcodebuild test -scheme voxlineTests -destination 'platform=macOS' -quiet 2>&1 | tail -50
```

If `xcodebuild` is too slow during iteration, scope to a single file with `-only-testing:voxlineTests/<TestSuite>`.

---

## File Structure Overview

**New files:**
- `voxline/Util/StringTrim.swift` — `String.trimmed` / `String.isBlank` extension
- `voxline/LLM/HTTPErrorMapping.swift` — shared HTTP-status → `LLMError` mapper
- `voxline/UI/WindowPresentation.swift` — `NSWindow.present()` helper for LSUIElement activation
- `voxlineTests/MockHTTPClient.swift` — shared test double promoted from inline duplicates

**Deleted files:**
- `voxline/Settings/GeneralSettingsApplier.swift` — single-conformer protocol replaced with closure

**Modified files (per-task table at top of each task).**

---

## Task 1: Add `String.trimmed` extension and replace inline trims

Tier 1 finding #3 — `.trimmingCharacters(in: .whitespacesAndNewlines)` is repeated 13 times across the codebase. Two ad-hoc helpers (`trimmedIsEmpty` in `WizardViewModel` and `trimmed` in `APIKeysSettingsViewModel`) reimplement the same logic locally.

**Files:**
- Create: `voxline/Util/StringTrim.swift`
- Modify: `voxline/Settings/APIKeysSettingsViewModel.swift:120-125`
- Modify: `voxline/Settings/Components/APIKeyRow.swift:48,68,90`
- Modify: `voxline/Settings/SettingsStatusViewModel.swift:48-51`
- Modify: `voxline/Settings/Components/CustomVocabularyListViewModel.swift:20,32`
- Modify: `voxline/Wizard/WizardViewModel.swift:96-99`
- Modify: `voxline/Wizard/WizardAPIKeyView.swift:74-78`
- Modify: `voxline/Storage/DictationHistoryStore.swift:46`
- Modify: `voxline/Storage/CustomVocabularyStore.swift:43`
- Modify: `voxline/Transcription/TranscriptionService.swift:121`

(Note: `voxline/Util/` is a new directory — Xcode picks up new files inside the source root via the file-system synchronized group. If your project uses explicit `pbxproj` membership, also add the file to the `voxline` target.)

- [ ] **Step 1: Create the extension file**

Write `voxline/Util/StringTrim.swift`:

```swift
import Foundation

extension String {
    /// Same as `trimmingCharacters(in: .whitespacesAndNewlines)`, but short
    /// enough to use inline at call sites without obscuring the surrounding
    /// expression.
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `true` when the string is empty after trimming surrounding whitespace
    /// and newlines. Used by Settings/Wizard validators that treat an
    /// all-whitespace API key or vocabulary entry as empty.
    var isBlank: Bool {
        trimmed.isEmpty
    }
}
```

- [ ] **Step 2: Verify the project compiles before edits**

Run:

```bash
xcodebuild build -scheme voxline -destination 'platform=macOS' -quiet 2>&1 | tail -20
```

Expected: build succeeds.

- [ ] **Step 3: Replace inline trims with `trimmed` / `isBlank`**

`voxline/Settings/APIKeysSettingsViewModel.swift` — replace the local helper at lines 120–125:

```swift
    private func trim(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
```

with direct `.trimmed` usage at every call site within that file. Delete the `trim` helper.

`voxline/Settings/Components/APIKeyRow.swift`:
- Line 48: `let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)` → `let trimmed = key.trimmed`
- Line 68: `key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty` → `key.isBlank`
- Line 90: `let trimmedEmpty = key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty` → `let trimmedEmpty = key.isBlank`

`voxline/Settings/SettingsStatusViewModel.swift` lines 49–50:

```swift
case .anthropic: live = keys.anthropicKey.trimmed
case .openai:    live = keys.openaiKey.trimmed
```

`voxline/Settings/Components/CustomVocabularyListViewModel.swift`:
- Line 20: `let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)` → `let trimmed = draft.trimmed`
- Line 32: same replacement

`voxline/Wizard/WizardViewModel.swift` — delete the local helper at lines 96–99:

```swift
    private func trimmedIsEmpty(_ s: String) -> Bool {
        s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
```

Replace its callers in that file with `<value>.isBlank`.

`voxline/Wizard/WizardAPIKeyView.swift` line 74–78: replace the `.trimmingCharacters(in: .whitespacesAndNewlines)` chain with `.trimmed`.

`voxline/Storage/DictationHistoryStore.swift` line 46: `cleanedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty` → `cleanedText.isBlank`.

`voxline/Storage/CustomVocabularyStore.swift` line 43: `let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)` → `let t = raw.trimmed`.

`voxline/Transcription/TranscriptionService.swift` line 121: replace the trailing `.trimmingCharacters(in: .whitespacesAndNewlines)` with `.trimmed`.

- [ ] **Step 4: Run the full test suite**

Run:

```bash
xcodebuild test -scheme voxlineTests -destination 'platform=macOS' -quiet 2>&1 | tail -30
```

Expected: all tests pass (no behavior change — just call-site rewrites).

- [ ] **Step 5: Commit**

```bash
git add voxline/Util/StringTrim.swift \
        voxline/Settings/APIKeysSettingsViewModel.swift \
        voxline/Settings/Components/APIKeyRow.swift \
        voxline/Settings/SettingsStatusViewModel.swift \
        voxline/Settings/Components/CustomVocabularyListViewModel.swift \
        voxline/Wizard/WizardViewModel.swift \
        voxline/Wizard/WizardAPIKeyView.swift \
        voxline/Storage/DictationHistoryStore.swift \
        voxline/Storage/CustomVocabularyStore.swift \
        voxline/Transcription/TranscriptionService.swift
git commit -m "refactor(simplify): add String.trimmed/isBlank, replace 13 inline trims"
```

---

## Task 2: Promote shared `MockHTTPClient` test double

Tier 1 finding #4 — `MockHTTPClient` is defined identically inside `AnthropicClientTests` and `OpenAIClientTests`.

**Files:**
- Create: `voxlineTests/MockHTTPClient.swift`
- Modify: `voxlineTests/AnthropicClientTests.swift:7-24`
- Modify: `voxlineTests/OpenAIClientTests.swift:8-26`

- [ ] **Step 1: Create the shared file**

Write `voxlineTests/MockHTTPClient.swift`:

```swift
import Foundation
@testable import voxline

/// Test double that captures the outbound request and returns a canned
/// `(data, status)` pair. Used by AnthropicClientTests, OpenAIClientTests, and
/// any other suite that needs to exercise an `HTTPClient` boundary.
final class MockHTTPClient: HTTPClient, @unchecked Sendable {
    var capturedRequest: URLRequest?
    var stubResponse: (data: Data, status: Int) = (Data(), 200)
    var stubError: Error?

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        capturedRequest = request
        if let stubError { throw stubError }
        let http = HTTPURLResponse(
            url: request.url!,
            statusCode: stubResponse.status,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        return (stubResponse.data, http)
    }
}
```

- [ ] **Step 2: Delete the inline copy in AnthropicClientTests.swift**

Remove lines 7–24 (the nested `final class MockHTTPClient: HTTPClient, @unchecked Sendable { … }` block) from `voxlineTests/AnthropicClientTests.swift`. The test methods continue to reference `MockHTTPClient` — they now resolve to the top-level type.

- [ ] **Step 3: Delete the inline copy in OpenAIClientTests.swift**

Remove lines 8–26 from `voxlineTests/OpenAIClientTests.swift`.

- [ ] **Step 4: Run tests**

```bash
xcodebuild test -scheme voxlineTests -destination 'platform=macOS' -only-testing:voxlineTests/AnthropicClientTests -only-testing:voxlineTests/OpenAIClientTests -quiet 2>&1 | tail -20
```

Expected: both suites pass.

- [ ] **Step 5: Commit**

```bash
git add voxlineTests/MockHTTPClient.swift \
        voxlineTests/AnthropicClientTests.swift \
        voxlineTests/OpenAIClientTests.swift
git commit -m "test(simplify): promote MockHTTPClient to shared test helper"
```

---

## Task 3: Consolidate LLM HTTP status mapping

Tier 1 finding #2 — `AnthropicClient.mapStatus` and `OpenAIClient.mapStatus` are byte-for-byte identical except for the provider name in log messages.

**Files:**
- Create: `voxline/LLM/HTTPErrorMapping.swift`
- Modify: `voxline/LLM/AnthropicClient.swift:40,45-62`
- Modify: `voxline/LLM/OpenAIClient.swift:44,67-84`

- [ ] **Step 1: Create the shared mapper**

Write `voxline/LLM/HTTPErrorMapping.swift`:

```swift
import Foundation

/// Maps an HTTP response from a provider API into either a no-op (success) or
/// the appropriate `LLMError`. Shared by `AnthropicClient` and `OpenAIClient`
/// — the only difference between their previous implementations was the
/// provider tag in log messages, threaded through here as `provider`.
///
/// 401 bodies are intentionally *not* logged: providers sometimes echo a
/// prefix of the offending API key in the error envelope.
func mapHTTPStatus(_ response: HTTPURLResponse, body: Data, provider: String) throws {
    switch response.statusCode {
    case 200..<300:
        return
    case 401:
        AppLog.llm.error("\(provider): 401 invalid API key")
        throw LLMError.invalidAPIKey
    case 429:
        AppLog.llm.error("\(provider): 429 rate limited")
        throw LLMError.rateLimited
    default:
        let text = String(data: body, encoding: .utf8) ?? ""
        let excerpt = text.prefix(200)
        AppLog.llm.error("\(provider): HTTP \(response.statusCode) body=\(excerpt)")
        throw LLMError.badStatus(code: response.statusCode, body: text)
    }
}
```

- [ ] **Step 2: Replace AnthropicClient's `mapStatus`**

In `voxline/LLM/AnthropicClient.swift`:
- Line 40: change `try mapStatus(response: response, body: data)` to `try mapHTTPStatus(response, body: data, provider: "anthropic")`.
- Delete lines 45–62 (the entire `private func mapStatus(response:body:)` method).

- [ ] **Step 3: Replace OpenAIClient's `mapStatus`**

In `voxline/LLM/OpenAIClient.swift`:
- Line 44: change `try mapStatus(response: response, body: data)` to `try mapHTTPStatus(response, body: data, provider: "openai")`.
- Delete lines 67–84.

- [ ] **Step 4: Run LLM tests**

```bash
xcodebuild test -scheme voxlineTests -destination 'platform=macOS' \
  -only-testing:voxlineTests/AnthropicClientTests \
  -only-testing:voxlineTests/OpenAIClientTests \
  -only-testing:voxlineTests/LLMServiceTests \
  -quiet 2>&1 | tail -20
```

Expected: all three suites pass. The `http_401_maps_to_invalidAPIKey`, `http_429_maps_to_rateLimited`, and `http_5xx_maps_to_badStatus_with_body` tests exercise the shared mapper.

- [ ] **Step 5: Commit**

```bash
git add voxline/LLM/HTTPErrorMapping.swift \
        voxline/LLM/AnthropicClient.swift \
        voxline/LLM/OpenAIClient.swift
git commit -m "refactor(simplify): extract shared LLM HTTP status mapper"
```

---

## Task 4: Replace `GeneralSettingsApplier` protocol with a closure

Tier 1 finding #1 — single production conformer (`AppCoordinator`); the protocol adds an indirection layer without an abstraction.

**Files:**
- Delete: `voxline/Settings/GeneralSettingsApplier.swift` (the `GeneralSettingsSnapshot` struct moves into `GeneralSettingsViewModel.swift`; the protocol is removed)
- Modify: `voxline/Settings/GeneralSettingsViewModel.swift:31,42-81,166-172`
- Modify: `voxline/voxlineApp.swift:47,463-(end-of-extension)`
- Modify: `voxlineTests/SettingsStatusViewModelTests.swift:102-103`
- Modify: `voxlineTests/GeneralSettingsViewModelTests.swift:233-240` (and call sites that pass `applier:`)

- [ ] **Step 1: Move `GeneralSettingsSnapshot` into the view model file and add the closure-typed init**

Open `voxline/Settings/GeneralSettingsViewModel.swift`. At the top of the file (above the `AudioDeviceRow` struct), add:

```swift
/// Snapshot the General settings VM hands to the coordinator on save.
struct GeneralSettingsSnapshot: Equatable {
    let chord: HotkeyChord
    let audioInputDeviceUID: String?
    let whisperModel: WhisperModel
    let playHotkeySounds: Bool
    let provider: LLMProvider
}
```

Change the stored property at line 31 from:

```swift
    private let applier: GeneralSettingsApplier
```

to:

```swift
    private let onApply: (GeneralSettingsSnapshot) -> Void
```

Update the convenience init signature (around line 42):

```swift
    convenience init(
        settings: AppSettings = AppSettings(),
        onApply: @escaping (GeneralSettingsSnapshot) -> Void,
        deviceEnumerator: @escaping () -> [AudioDevice] = AudioDeviceEnumerator.inputDevices
    ) {
        self.init(
            settings: settings,
            onApply: onApply,
            deviceEnumerator: deviceEnumerator,
            loginItemService: LoginItemService(),
            vocabulary: CustomVocabularyStore()
        )
    }
```

Update the designated init (around line 56):

```swift
    init(
        settings: AppSettings = AppSettings(),
        onApply: @escaping (GeneralSettingsSnapshot) -> Void,
        deviceEnumerator: @escaping () -> [AudioDevice] = AudioDeviceEnumerator.inputDevices,
        loginItemService: LoginItemService,
        vocabulary: CustomVocabularyStore = CustomVocabularyStore()
    ) {
        self.settings = settings
        self.onApply = onApply
        // ... unchanged body, but replace `self.applier = applier` with the line above ...
```

Update the `commit()` method (around line 166):

```swift
    private func commit() {
        var s = settings
        s.hotkeyChord = chord
        s.audioInputDeviceUID = audioInputDeviceUID
        s.whisperModel = whisperModel
        s.playHotkeySounds = playHotkeySounds
        s.llmProvider = provider
        settings = s
        onApply(GeneralSettingsSnapshot(
            chord: chord,
            audioInputDeviceUID: audioInputDeviceUID,
            whisperModel: whisperModel,
            playHotkeySounds: playHotkeySounds,
            provider: provider
        ))
    }
```

- [ ] **Step 2: Delete the protocol file**

```bash
git rm voxline/Settings/GeneralSettingsApplier.swift
```

- [ ] **Step 3: Update `voxlineApp.swift` to pass a closure**

In `voxline/voxlineApp.swift`:

Line 47 currently reads (within `SettingsView` instantiation, approximately):

```swift
                generalVM: GeneralSettingsViewModel(applier: delegate.coordinator),
```

Change to:

```swift
                generalVM: GeneralSettingsViewModel(onApply: { [weak coordinator = delegate.coordinator] snapshot in
                    coordinator?.apply(snapshot)
                }),
```

At line 463, the existing block reads:

```swift
extension AppCoordinator: GeneralSettingsApplier {
    func apply(_ snapshot: GeneralSettingsSnapshot) {
        // ... body ...
    }
}
```

Change it to a regular method on `AppCoordinator` — delete the `extension AppCoordinator: GeneralSettingsApplier {` wrapper and place the `func apply(_ snapshot: GeneralSettingsSnapshot)` declaration inside the main `AppCoordinator` class (or leave it in an `extension AppCoordinator { … }` without the protocol conformance). The method body is unchanged.

- [ ] **Step 4: Update test fixtures**

In `voxlineTests/GeneralSettingsViewModelTests.swift` lines 233–240, the file currently defines:

```swift
private struct NoopApplier: GeneralSettingsApplier {
    func apply(_ snapshot: GeneralSettingsSnapshot) {}
}

private final class RecordingApplier: GeneralSettingsApplier {
    var applied: GeneralSettingsSnapshot?
    func apply(_ snapshot: GeneralSettingsSnapshot) { applied = snapshot }
}
```

Replace those types with:

```swift
private let noopApply: (GeneralSettingsSnapshot) -> Void = { _ in }

@MainActor
private final class ApplyRecorder {
    var applied: GeneralSettingsSnapshot?
    func record(_ snapshot: GeneralSettingsSnapshot) { applied = snapshot }
}
```

Search the rest of the file for `NoopApplier()` / `RecordingApplier()` and replace:
- `applier: NoopApplier()` → `onApply: noopApply`
- `applier: recordingApplier` (where `recordingApplier` is a `RecordingApplier`) → `onApply: { recorder.record($0) }` (using an `ApplyRecorder` instance named `recorder`)

In `voxlineTests/SettingsStatusViewModelTests.swift` lines 102–103, do the same replacement: delete `NoopApplier` struct, replace any `applier: NoopApplier()` callsites with `onApply: { _ in }`.

- [ ] **Step 5: Run tests**

```bash
xcodebuild test -scheme voxlineTests -destination 'platform=macOS' \
  -only-testing:voxlineTests/GeneralSettingsViewModelTests \
  -only-testing:voxlineTests/SettingsStatusViewModelTests \
  -quiet 2>&1 | tail -30
```

Expected: both suites pass.

- [ ] **Step 6: Run the full test suite to catch unexpected callers**

```bash
xcodebuild test -scheme voxlineTests -destination 'platform=macOS' -quiet 2>&1 | tail -30
```

Expected: all tests pass. If any test file fails compilation because it still references `GeneralSettingsApplier`, update those references using the same pattern from Step 4.

- [ ] **Step 7: Commit**

```bash
git add -A voxline/Settings/ voxline/voxlineApp.swift voxlineTests/
git commit -m "refactor(simplify): replace GeneralSettingsApplier protocol with closure"
```

---

## Task 5: Replace `loaded` sentinel with a `syncing` helper

Tier 2 finding #6 — the `loaded = false; mutate; loaded = true` pattern is duplicated across three methods in `GeneralSettingsViewModel`.

**Files:**
- Modify: `voxline/Settings/GeneralSettingsViewModel.swift:99-149`

- [ ] **Step 1: Add the `syncing` helper**

In `voxline/Settings/GeneralSettingsViewModel.swift`, add this method below the existing `commit()` method (so it's grouped with the other `private` methods):

```swift
    /// Run `mutations` with `loaded == false` so the `didSet` → `commit()`
    /// chain on `chord`, `audioInputDeviceUID`, etc. does not fire. Use this
    /// when batch-syncing the view model to a backing store (UserDefaults,
    /// `LoginItemService.status`, the Reset-to-defaults path) where the
    /// changes already represent ground truth and committing them back would
    /// be redundant at best, recursive at worst.
    private func syncing(_ mutations: () -> Void) {
        loaded = false
        mutations()
        loaded = true
    }
```

- [ ] **Step 2: Replace the three manual sync blocks**

`refreshLoginItemStatus()` (around line 102) — replace this block:

```swift
        if launchAtLogin != actual {
            loaded = false
            launchAtLogin = actual
            loaded = true
        }
```

with:

```swift
        if launchAtLogin != actual {
            syncing { launchAtLogin = actual }
        }
```

Delete the existing 5-line "Same trick as resetToDefaults" comment block — the `syncing` name + its docstring make the rationale clear without a callsite comment.

`refreshFromUserDefaults()` (around line 122) — replace:

```swift
    func refreshFromUserDefaults() {
        loaded = false
        chord = settings.hotkeyChord
        audioInputDeviceUID = settings.audioInputDeviceUID
        whisperModel = settings.whisperModel
        playHotkeySounds = settings.playHotkeySounds
        provider = settings.llmProvider
        loaded = true
    }
```

with:

```swift
    /// Re-reads UserDefaults-backed settings so the Settings UI reflects
    /// writes made elsewhere in the app (e.g., the wizard's `advance()`
    /// persisting `selectedProvider`). The view model otherwise caches the
    /// value from init and would show stale state on subsequent window
    /// opens. Called via `.task` on the Settings window the same way
    /// `refreshLoginItemStatus()` is.
    func refreshFromUserDefaults() {
        syncing {
            chord = settings.hotkeyChord
            audioInputDeviceUID = settings.audioInputDeviceUID
            whisperModel = settings.whisperModel
            playHotkeySounds = settings.playHotkeySounds
            provider = settings.llmProvider
        }
    }
```

(Keep the existing 6-line docstring — that's a real why-comment about cross-source-of-truth reconciliation, unlike the deleted "Guard with `loaded = false`" implementation note.)

`resetToDefaults()` (around line 139) — replace:

```swift
    func resetToDefaults() {
        loaded = false
        chord = .default
        audioInputDeviceUID = nil
        whisperModel = .default
        playHotkeySounds = true
        provider = .anthropic
        loaded = true
        vocabulary.save([])
        commit()
    }
```

with:

```swift
    /// Restore Spec defaults: hotkey to Left Ctrl + Left Option, system-default
    /// mic, large-v3-turbo, sounds on. Performs one batched commit so the
    /// applier sees a single coherent snapshot rather than four partial ones.
    /// Launch-at-Login is intentionally left untouched — Reset is for pipeline
    /// settings, not OS-level integration.
    func resetToDefaults() {
        syncing {
            chord = .default
            audioInputDeviceUID = nil
            whisperModel = .default
            playHotkeySounds = true
            provider = .anthropic
        }
        vocabulary.save([])
        commit()
    }
```

- [ ] **Step 3: Run tests**

```bash
xcodebuild test -scheme voxlineTests -destination 'platform=macOS' \
  -only-testing:voxlineTests/GeneralSettingsViewModelTests \
  -quiet 2>&1 | tail -20
```

Expected: all tests pass. The behavior is identical — `syncing` is a 3-line refactor of the existing pattern.

- [ ] **Step 4: Commit**

```bash
git add voxline/Settings/GeneralSettingsViewModel.swift
git commit -m "refactor(simplify): collapse loaded-sentinel guard into syncing helper"
```

---

## Task 6: Use Apple's AX subrole constants

Tier 2 finding #8 — `FocusedField.swift` compares against raw `"AXSecureTextField"` / `"AXSearchField"` strings. Apple already exports `kAXSecureTextFieldSubrole` and `kAXSearchFieldSubrole` (already in use in `ClipboardInjector.swift:226`).

**Files:**
- Modify: `voxline/Modes/FocusedField.swift:1,25-26`

- [ ] **Step 1: Add the import and switch to Apple constants**

At the top of `voxline/Modes/FocusedField.swift`, change:

```swift
import Foundation
```

to:

```swift
import Foundation
import ApplicationServices
```

Replace lines 25–26 (currently):

```swift
        if subrole == "AXSecureTextField" { return .secure }
        if subrole == "AXSearchField" { return .search }
```

with:

```swift
        if subrole == (kAXSecureTextFieldSubrole as String) { return .secure }
        if subrole == (kAXSearchFieldSubrole as String) { return .search }
```

- [ ] **Step 2: Run FocusedField tests**

```bash
xcodebuild test -scheme voxlineTests -destination 'platform=macOS' \
  -only-testing:voxlineTests/FocusedFieldTests \
  -quiet 2>&1 | tail -15
```

Expected: pass. The Apple constants are guaranteed to have the same string values used previously — if the tests construct `FocusedField` with the raw `"AXSecureTextField"` string, those continue to compare equal because the constant's bridged-`String` value is `"AXSecureTextField"`.

- [ ] **Step 3: Commit**

```bash
git add voxline/Modes/FocusedField.swift
git commit -m "refactor(simplify): use Apple AX subrole constants in FocusedField"
```

---

## Task 7: Extract `NSWindow.present()` activation helper

Tier 2 finding #5 (conservative version) — the original ranking suggested merging `AboutWindowController`, `HistoryWindowController`, and `ModelDownloadWindow` into one `WindowManager`. On closer inspection that would create a god-class without a clear win: each controller has different content-view construction, frame sizing, and lifecycle (only `ModelDownloadWindow` exposes `close()`). What's actually duplicated is the **activation ritual** (the deprecated-but-required `NSApp.activate(ignoringOtherApps: true)` + `makeKeyAndOrderFront(nil)` pair, plus the AppKit z-order rationale comment). Extract that.

**Files:**
- Create: `voxline/UI/WindowPresentation.swift`
- Modify: `voxline/UI/AboutWindowController.swift:9-12,26-33`
- Modify: `voxline/UI/HistoryWindowController.swift:15-18,28-30`
- Modify: `voxline/UI/ModelDownloadWindow.swift:11-14,32-34`
- Modify: `voxline/Wizard/FirstRunWindowController.swift:43` (comment cross-reference)

- [ ] **Step 1: Create the helper**

Write `voxline/UI/WindowPresentation.swift`:

```swift
import AppKit

@MainActor
extension NSWindow {
    /// Activate the app and bring this window forward with the sequence
    /// required by LSUIElement (menu-bar) apps. Activate BEFORE ordering the
    /// window so the activation-policy flip lands before AppKit decides
    /// z-order; otherwise the window appears behind whatever app was
    /// previously frontmost. `ignoringOtherApps: true` is deprecated but
    /// still the documented escape hatch for accessory apps —
    /// `NSApp.activate()` alone is unreliable here.
    func presentInAccessoryApp() {
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
    }
}
```

- [ ] **Step 2: Use the helper in AboutWindowController**

In `voxline/UI/AboutWindowController.swift`, replace the body of `show(env:)`:

```swift
    func show(env: SupportEnvironment) {
        if let w = window {
            w.presentInAccessoryApp()
            return
        }
        let host = NSHostingView(rootView: AboutView(env: env))
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "About Voxline"
        win.contentView = host
        win.center()
        win.isReleasedWhenClosed = false
        self.window = win
        win.presentInAccessoryApp()
    }
```

The 8-line "LSUIElement (menu-bar) apps" rationale comment goes away — it now lives on `presentInAccessoryApp()`.

- [ ] **Step 3: Use the helper in HistoryWindowController**

In `voxline/UI/HistoryWindowController.swift`, replace the body of `show(store:state:)`:

```swift
    func show(store: DictationHistoryStore, state: AppState) {
        if let w = window {
            w.presentInAccessoryApp()
            return
        }
        let host = NSHostingController(rootView: HistoryView(store: store, state: state))
        let win = NSWindow(contentViewController: host)
        win.title = "Voxline History"
        win.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        win.setContentSize(NSSize(width: 920, height: 480))
        win.isReleasedWhenClosed = false
        win.center()
        self.window = win
        win.presentInAccessoryApp()
    }
```

Drop the `// See AboutWindowController.show for why this pair is in this order.` comment.

- [ ] **Step 4: Use the helper in ModelDownloadWindow**

In `voxline/UI/ModelDownloadWindow.swift`, replace the body of `show(state:)`:

```swift
    func show(state: AppState) {
        if let window {
            window.presentInAccessoryApp()
            return
        }

        let view = ModelDownloadView(state: state)
        let host = NSHostingView(rootView: view)

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 170),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "Preparing Voxline"
        win.contentView = host
        win.center()
        win.isReleasedWhenClosed = false

        self.window = win
        win.presentInAccessoryApp()
    }
```

Drop the `// See AboutWindowController.show for why this pair is in this order.` comment. Leave the `close()` method unchanged.

- [ ] **Step 5: Update FirstRunWindowController to use the helper**

Open `voxline/Wizard/FirstRunWindowController.swift`. Find the spot at line 43 with the `// See AboutWindowController.show for why this pair is in this order.` comment and the surrounding `NSApp.activate(ignoringOtherApps: true)` + `makeKeyAndOrderFront(nil)` pair. Replace the pair with `<window>.presentInAccessoryApp()` (using whatever local variable name holds the `NSWindow`). Delete the comment.

- [ ] **Step 6: Build the app (no test coverage for window activation, but verify it compiles)**

```bash
xcodebuild build -scheme voxline -destination 'platform=macOS' -quiet 2>&1 | tail -20
```

Expected: build succeeds.

- [ ] **Step 7: Run full test suite**

```bash
xcodebuild test -scheme voxlineTests -destination 'platform=macOS' -quiet 2>&1 | tail -20
```

Expected: pass — the change is pure code motion.

- [ ] **Step 8: Manual smoke check (do not skip)**

Window activation is not unit-tested. Run the app, then verify:

1. From the menu bar, click Voxline → About — the About window appears in front of other apps.
2. From the menu bar, click Voxline → History (or whatever menu opens history) — the History window appears in front.
3. (If the dev machine has no Whisper model cached) launch the app — the Preparing Voxline window appears in front.
4. Click each window's traffic-light close, then re-open from the menu — the window comes back to the front.

If any of these fail (e.g. window appears behind another app), the activation ordering inside `presentInAccessoryApp()` is wrong — most likely the `activate` and `makeKeyAndOrderFront` calls need to remain in their original order, which is the order written in the helper.

- [ ] **Step 9: Commit**

```bash
git add voxline/UI/WindowPresentation.swift \
        voxline/UI/AboutWindowController.swift \
        voxline/UI/HistoryWindowController.swift \
        voxline/UI/ModelDownloadWindow.swift \
        voxline/Wizard/FirstRunWindowController.swift
git commit -m "refactor(simplify): extract NSWindow.presentInAccessoryApp helper"
```

---

## Task 8 (optional): Convert `LoginItemBackend` from protocol to struct

Tier 2 finding #7. **Read this section before starting** — the win is marginal and the change touches both `LoginItemService` and its test suite. If the LOC count after conversion turns out to be a wash, abandon the task.

**Why it might be worth doing:** the protocol exists solely as a test seam over `SMAppService`. A value-type "function record" struct removes one type (`DefaultLoginItemBackend`) and eliminates the `@MainActor protocol` / `@MainActor struct conformer` pair.

**Why it might not:** the protocol is already small (3 members, 13 LOC), and the struct version is similar in LOC. The test stub becomes slightly more awkward (closure-fields instead of a class with stored state).

**Files:**
- Modify: `voxline/Settings/LoginItemService.swift`
- Modify: `voxlineTests/LoginItemServiceTests.swift:59` (and the `StubLoginBackend` class plus its call sites)

- [ ] **Step 1: Rewrite `LoginItemService.swift`**

Replace the entire file contents:

```swift
import ServiceManagement

@MainActor
struct LoginItemBackend {
    var status: () -> SMAppService.Status
    var register: () throws -> Void
    var unregister: () throws -> Void

    static let live: LoginItemBackend = {
        let service = SMAppService.mainApp
        return LoginItemBackend(
            status: { service.status },
            register: { try service.register() },
            unregister: { try service.unregister() }
        )
    }()
}

@MainActor
final class LoginItemService {
    enum Status: Equatable {
        case enabled
        case disabled
        case requiresApproval
        case unsupported
    }

    private let backend: LoginItemBackend

    init(backend: LoginItemBackend = .live) {
        self.backend = backend
    }

    var status: Status {
        switch backend.status() {
        case .enabled: return .enabled
        case .notRegistered: return .disabled
        case .notFound: return .disabled
        case .requiresApproval: return .requiresApproval
        @unknown default: return .unsupported
        }
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try backend.register()
        } else {
            try backend.unregister()
        }
    }
}
```

- [ ] **Step 2: Rewrite the test stub**

Open `voxlineTests/LoginItemServiceTests.swift`. The current `StubLoginBackend` class (starts at line 59) is a `final class` with mutable state tracking which methods were called and what status to return. Replace it with a helper that builds a `LoginItemBackend` struct from explicit inputs and exposes the call counters via an observer object.

At the bottom of the file, replace the `StubLoginBackend` class with:

```swift
/// Test helper: build a `LoginItemBackend` whose `status()` reads from a
/// shared box and whose `register`/`unregister` push to that same box. The
/// returned `Counter` is observable from the test so assertions can check
/// "did we call register?" / "did we call unregister?".
@MainActor
final class LoginItemCounter {
    var status: SMAppService.Status
    var registered = false
    var unregistered = false
    var registerError: Error?
    var unregisterError: Error?

    init(status: SMAppService.Status) {
        self.status = status
    }

    var backend: LoginItemBackend {
        LoginItemBackend(
            status: { self.status },
            register: {
                self.registered = true
                if let error = self.registerError { throw error }
            },
            unregister: {
                self.unregistered = true
                if let error = self.unregisterError { throw error }
            }
        )
    }
}
```

Update each test that currently constructs `StubLoginBackend(...)`. Concrete examples (line numbers approximate; preserve the exact assertion in each):

Before:
```swift
let svc = LoginItemService(backend: StubLoginBackend(status: .enabled))
```

After:
```swift
let counter = LoginItemCounter(status: .enabled)
let svc = LoginItemService(backend: counter.backend)
```

Before (counter-flavored test):
```swift
let backend = StubLoginBackend(status: .notRegistered)
let svc = LoginItemService(backend: backend)
try svc.setEnabled(true)
#expect(backend.registered == true)
```

After:
```swift
let counter = LoginItemCounter(status: .notRegistered)
let svc = LoginItemService(backend: counter.backend)
try svc.setEnabled(true)
#expect(counter.registered == true)
```

Apply the same `backend.X` → `counter.X` rename throughout the file.

- [ ] **Step 3: Update the convenience init site**

`LoginItemService()` previously had an explicit no-arg convenience init that called `init(backend: DefaultLoginItemBackend())`. The new design uses `init(backend: LoginItemBackend = .live)` — `LoginItemService()` continues to work. Search for any other `LoginItemService(` construction in the codebase to make sure no caller still passes a deprecated `DefaultLoginItemBackend()`:

```bash
grep -rn "DefaultLoginItemBackend\|StubLoginBackend" --include="*.swift" voxline voxlineTests
```

Expected: zero matches after this task (every reference has been replaced).

- [ ] **Step 4: Run tests**

```bash
xcodebuild test -scheme voxlineTests -destination 'platform=macOS' \
  -only-testing:voxlineTests/LoginItemServiceTests \
  -only-testing:voxlineTests/GeneralSettingsViewModelTests \
  -quiet 2>&1 | tail -20
```

Expected: pass. (`GeneralSettingsViewModelTests` exercises `LoginItemService` indirectly via the launch-at-login toggle.)

- [ ] **Step 5: Decision point — keep or revert?**

Compare LOC: `git diff --stat HEAD voxline/Settings/LoginItemService.swift voxlineTests/LoginItemServiceTests.swift`. If the change is < 5 net lines saved AND the test file got longer or harder to read, run `git checkout -- voxline/Settings/LoginItemService.swift voxlineTests/LoginItemServiceTests.swift` and skip Step 6. The protocol version was fine.

- [ ] **Step 6: Commit (only if Step 5 said keep)**

```bash
git add voxline/Settings/LoginItemService.swift \
        voxlineTests/LoginItemServiceTests.swift
git commit -m "refactor(simplify): convert LoginItemBackend to value-typed seam"
```

---

## Completion checklist

After all tasks land, run a final full-suite sweep and a smoke build:

- [ ] **All tests pass:**

```bash
xcodebuild test -scheme voxlineTests -destination 'platform=macOS' 2>&1 | tail -10
```

- [ ] **Release build still compiles:**

```bash
xcodebuild build -scheme voxline -configuration Release -destination 'platform=macOS' -quiet 2>&1 | tail -10
```

- [ ] **No dangling references to deleted types:**

```bash
grep -rn "GeneralSettingsApplier\|DefaultLoginItemBackend\|StubLoginBackend" --include="*.swift" voxline voxlineTests
```

Expected: zero matches (after Tasks 4 and optionally 8).

- [ ] **Manual smoke test of UI flows touched by Task 7:** About, History, Preparing-Voxline window activation (see Task 7 Step 8).

---

## Tasks intentionally omitted

For transparency, these Tier 2 items from the original ranking are **not** in this plan:

- **Wizard step view inlining** (Tier 3, originally listed as a judgment call). SwiftUI codebases often prefer one-view-per-file for diff locality. Skipped.
- **`SettingsStatusViewModel` deletion** (disputed between agents). The class is purely derived state but the indirection is harmless. Skipped.
- **`CapturePipeline` 10-param init grouping**. Each parameter is a test seam; bundling into a struct trades param sprawl for a new type and indirection. Not a clear win. Skipped.
- **`AppCoordinator` decomposition**. Largest finding but lowest-confidence — for a single-developer macOS app, an omnibus orchestrator is often the right shape. Skipped.
