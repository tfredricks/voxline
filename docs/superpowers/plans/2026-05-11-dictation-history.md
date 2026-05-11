# Dictation History Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a "Recent dictations" submenu in the menu bar that lists the last 10 cleaned dictations; clicking a row copies its text to the clipboard with a brief toast; persist across restarts; include a "Clear History" action.

**Architecture:** A new `@MainActor` observable `DictationHistoryStore` owns an in-memory `[DictationHistoryItem]` (max 10, newest first) backed by JSON in `UserDefaults`. `CapturePipeline` calls `store.record(cleanedText:)` after a successful LLM cleanup. `MenuBarContent` reads `store.items` to render a submenu of clickable rows that copy to `NSPasteboard.general` and trigger a transient toast via `RecordingPillWindow`.

**Tech Stack:** Swift 6, SwiftUI (`MenuBarExtra`, `Menu`), AppKit (`NSPasteboard`, `NSPanel`), Foundation (`UserDefaults`, `JSONEncoder`/`Decoder`, `RelativeDateTimeFormatter`), swift-testing (`@Suite`/`@Test`/`#expect`).

**Decisions baked in (from spec):**
- Store cleaned text only (no raw transcript, no target app, no model).
- `UserDefaults` storage (not a JSON file). Matches existing `HotkeyChord` pattern.
- Cap is hardcoded `10`. No user setting in v1.
- Click action is copy-to-clipboard + toast. Not re-paste.
- "Clear History" action exists. No "Pause history" toggle (deferred to feature #15).
- Whitespace-only cleaned text is skipped (defensive).
- Toast text is `"Copied"`. Duration 1.2s. Shown via the existing pill window.

**Out of scope (deferred):**
- Feature #15 controls (pause history, audio retention, transcript-logging toggles).
- A History tab/section in Settings.
- Search, tagging, or longer history.
- Re-run cleanup with a different prompt (requires raw transcript we don't store).

---

## File Map

**New:**
- `voxline/Storage/DictationHistoryStore.swift` — `DictationHistoryItem` struct + `DictationHistoryStore` class
- `voxline/MenuBar/DictationHistoryMenu.swift` — SwiftUI submenu view + label-formatting helpers
- `voxlineTests/DictationHistoryStoreTests.swift`
- `voxlineTests/DictationHistoryMenuTests.swift` — label-formatting tests (pure functions)

**Modified:**
- `voxline/AppState.swift` — add `var toastMessage: String?`
- `voxline/Pipeline/CapturePipeline.swift` — accept `historyStore`, call `record` after cleanup
- `voxline/voxlineApp.swift` — instantiate store on `AppDelegate`, inject into pipeline and menu
- `voxline/MenuBar/MenuBarContent.swift` — render the "Recent dictations" submenu
- `voxline/UI/RecordingPillView.swift` — render a third case for `toastMessage`
- `voxline/UI/RecordingPillWindow.swift` — show panel when `toastMessage != nil`
- `voxlineTests/CapturePipelineTests.swift` — pass a real store; assert it records on success
- `docs/features.md` — mark item #16 as `[x]`

---

## Task 1: `DictationHistoryItem` + `DictationHistoryStore` (model + persistence)

**Files:**
- Create: `voxline/Storage/DictationHistoryStore.swift`
- Test: `voxlineTests/DictationHistoryStoreTests.swift`

The whole store and item type live in one file. Pure model + persistence; no UI.

- [ ] **Step 1: Write the failing tests**

Create `voxlineTests/DictationHistoryStoreTests.swift` with this content:

```swift
import Testing
import Foundation
@testable import voxline

@Suite @MainActor struct DictationHistoryStoreTests {

    /// Per-test isolated suite so we don't trample the user's real defaults.
    private func makeDefaults() -> UserDefaults {
        let suiteName = "voxline-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test func record_addsNewestFirst() {
        let store = DictationHistoryStore(defaults: makeDefaults())
        store.record(cleanedText: "first")
        store.record(cleanedText: "second")
        #expect(store.items.count == 2)
        #expect(store.items[0].cleanedText == "second")
        #expect(store.items[1].cleanedText == "first")
    }

    @Test func record_capsAtTen() {
        let store = DictationHistoryStore(defaults: makeDefaults())
        for i in 1...12 {
            store.record(cleanedText: "item \(i)")
        }
        #expect(store.items.count == 10)
        // Newest (item 12) at index 0; oldest retained (item 3) at index 9.
        #expect(store.items[0].cleanedText == "item 12")
        #expect(store.items[9].cleanedText == "item 3")
    }

    @Test func record_skipsWhitespaceOnly() {
        let store = DictationHistoryStore(defaults: makeDefaults())
        store.record(cleanedText: "")
        store.record(cleanedText: "   \n\t  ")
        #expect(store.items.isEmpty)
    }

    @Test func clear_emptiesList() {
        let store = DictationHistoryStore(defaults: makeDefaults())
        store.record(cleanedText: "a")
        store.record(cleanedText: "b")
        store.clear()
        #expect(store.items.isEmpty)
    }

    @Test func persistence_roundTrip() {
        let defaults = makeDefaults()
        let writer = DictationHistoryStore(defaults: defaults)
        writer.record(cleanedText: "alpha")
        writer.record(cleanedText: "beta")
        writer.record(cleanedText: "gamma")

        let reader = DictationHistoryStore(defaults: defaults)
        #expect(reader.items.count == 3)
        #expect(reader.items[0].cleanedText == "gamma")
        #expect(reader.items[1].cleanedText == "beta")
        #expect(reader.items[2].cleanedText == "alpha")
    }

    @Test func persistence_handlesCorruptData() {
        let defaults = makeDefaults()
        defaults.set(Data([0x00, 0x01, 0x02]), forKey: "voxline.history.dictations")
        let store = DictationHistoryStore(defaults: defaults)
        #expect(store.items.isEmpty)
    }

    @Test func clear_persistsEmpty() {
        let defaults = makeDefaults()
        let writer = DictationHistoryStore(defaults: defaults)
        writer.record(cleanedText: "a")
        writer.clear()
        let reader = DictationHistoryStore(defaults: defaults)
        #expect(reader.items.isEmpty)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:
```bash
cd /Users/toddfredricks/GitHub/voxline && xcodebuild -scheme voxline -destination 'platform=macOS' test -only-testing:voxlineTests/DictationHistoryStoreTests 2>&1 | tail -30
```

Expected: build failure — `DictationHistoryStore` is undefined.

- [ ] **Step 3: Write minimal implementation**

Create `voxline/Storage/DictationHistoryStore.swift`:

```swift
import Foundation
import Observation

/// One entry in the dictation history. Stores cleaned text only — no raw
/// transcript, no target app, no model. Smaller storage footprint and less
/// to worry about for privacy. Future feature #15 controls can wrap recording
/// with a no-op without touching this type.
struct DictationHistoryItem: Codable, Identifiable, Equatable {
    let id: UUID
    let timestamp: Date
    let cleanedText: String

    init(id: UUID = UUID(), timestamp: Date = Date(), cleanedText: String) {
        self.id = id
        self.timestamp = timestamp
        self.cleanedText = cleanedText
    }
}

/// In-memory list (max 10, newest first) of recent cleaned dictations,
/// JSON-encoded into UserDefaults. Same persistence pattern as `HotkeyChord`.
@Observable
@MainActor
final class DictationHistoryStore {

    private static let key = "voxline.history.dictations"
    private static let maxItems = 10

    private(set) var items: [DictationHistoryItem] = []

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.items = Self.load(defaults: defaults)
    }

    /// Prepend a new entry. Whitespace-only text is ignored. Caps at 10 by
    /// dropping the oldest entries.
    func record(cleanedText: String) {
        let trimmed = cleanedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let item = DictationHistoryItem(cleanedText: cleanedText)
        var next = [item] + items
        if next.count > Self.maxItems {
            next = Array(next.prefix(Self.maxItems))
        }
        items = next
        persist()
    }

    /// Wipe the list and persist the empty state.
    func clear() {
        items = []
        persist()
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(items)
            defaults.set(data, forKey: Self.key)
        } catch {
            // Encoding can't realistically fail for this shape, but if it
            // ever does we'd rather lose history-on-disk than crash.
        }
    }

    private static func load(defaults: UserDefaults) -> [DictationHistoryItem] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([DictationHistoryItem].self, from: data)) ?? []
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run:
```bash
cd /Users/toddfredricks/GitHub/voxline && xcodebuild -scheme voxline -destination 'platform=macOS' test -only-testing:voxlineTests/DictationHistoryStoreTests 2>&1 | tail -30
```

Expected: all 7 tests pass.

- [ ] **Step 5: Commit**

```bash
cd /Users/toddfredricks/GitHub/voxline && git add voxline/Storage/DictationHistoryStore.swift voxlineTests/DictationHistoryStoreTests.swift && git commit -m "feat(history): add DictationHistoryStore with UserDefaults persistence"
```

---

## Task 2: Pipeline records cleaned text into the store

**Files:**
- Modify: `voxline/Pipeline/CapturePipeline.swift` (add `historyStore` param + record call)
- Modify: `voxlineTests/CapturePipelineTests.swift` (pass store in, assert on it)

`CapturePipeline.init` gains a new `historyStore: DictationHistoryStore` parameter. After `state.lastCleanedText = cleaned` (currently line 175), call `historyStore.record(cleanedText: cleaned)`.

- [ ] **Step 1: Write the failing test**

In `voxlineTests/CapturePipelineTests.swift`, modify the `makePipeline` helper to also create and return a `DictationHistoryStore`, then add a new test.

First, change `makePipeline`'s return tuple to include `history`:

```swift
private func makePipeline(
    frontmostBundleID: String? = "com.tinyspeck.slackmacgap",
    focusedField: FocusedField? = nil,
    modes: [Mode] = [
        Mode(bundleID: "com.tinyspeck.slackmacgap", displayName: "Slack", prompt: "slack-prompt", model: nil, temperature: nil),
        Mode(bundleID: "*", displayName: "Default", prompt: "default-prompt", model: nil, temperature: nil)
    ]
) -> (pipe: CapturePipeline, state: AppState, capture: FakeCapture, transcriber: FakeTranscriber, llm: FakeLLM, frontmost: FakeFrontmost, inspector: FakeFieldInspector, injector: FakeInjector, history: DictationHistoryStore) {
    let state = AppState()
    let capture = FakeCapture()
    let transcriber = FakeTranscriber()
    let llm = FakeLLM()
    let front = FakeFrontmost(); front.bundleID = frontmostBundleID
    let inspector = FakeFieldInspector(); inspector.field = focusedField
    let injector = FakeInjector()
    let router = ModeRouter(modes: modes)
    let suiteName = "voxline-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    let history = DictationHistoryStore(defaults: defaults)
    let pipe = CapturePipeline(
        state: state, capture: capture, transcriber: transcriber,
        llm: llm, modes: router, frontmost: front,
        fieldInspector: inspector, injector: injector,
        historyStore: history
    )
    return (pipe, state, capture, transcriber, llm, front, inspector, injector, history)
}
```

Then update every existing call site in the file. Each `let (pipe, state, capture, _, _, _, _, _) = makePipeline()` becomes `let (pipe, state, capture, _, _, _, _, _, _) = makePipeline()` — add one extra `_` to the tuple destructure. There are roughly 15 such sites; update them all so the file still compiles.

Then add the new test at the bottom of the suite:

```swift
@Test func finalizeRecording_recordsCleanedTextInHistory() async throws {
    let (pipe, state, _, transcriber, llm, _, _, _, history) = makePipeline()
    transcriber.nextResult = .success("uh hello there")
    llm.nextResult = .success("Hello there.")
    await startAndFinalize(pipe, state: state)
    #expect(history.items.count == 1)
    #expect(history.items[0].cleanedText == "Hello there.")
}

@Test func empty_transcript_doesNotRecordInHistory() async throws {
    let (pipe, state, _, transcriber, _, _, _, _, history) = makePipeline()
    transcriber.nextResult = .success("")
    await startAndFinalize(pipe, state: state)
    #expect(history.items.isEmpty)
}

@Test func transcriptionFailure_doesNotRecordInHistory() async throws {
    struct StubError: Error {}
    let (pipe, state, _, transcriber, _, _, _, _, history) = makePipeline()
    transcriber.nextResult = .failure(StubError())
    await startAndFinalize(pipe, state: state)
    #expect(history.items.isEmpty)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:
```bash
cd /Users/toddfredricks/GitHub/voxline && xcodebuild -scheme voxline -destination 'platform=macOS' test -only-testing:voxlineTests/CapturePipelineTests 2>&1 | tail -30
```

Expected: build failure — `CapturePipeline.init` doesn't accept `historyStore:`.

- [ ] **Step 3: Add the parameter and record call**

In `voxline/Pipeline/CapturePipeline.swift`:

Add a stored property near the others (after `private let injector`):

```swift
    private let historyStore: DictationHistoryStore
```

Extend the initializer signature and assignment. Replace the init block (lines 19–47) with:

```swift
    init(
        state: AppState,
        capture: AudioCapturing,
        transcriber: Transcribing,
        llm: LLMServing,
        modes: ModeResolving,
        frontmost: FrontmostAppProviding,
        fieldInspector: FocusedFieldInspecting,
        injector: ClipboardInjecting,
        historyStore: DictationHistoryStore
    ) {
        self.state = state
        self.capture = capture
        self.transcriber = transcriber
        self.llm = llm
        self.modes = modes
        self.frontmost = frontmost
        self.fieldInspector = fieldInspector
        self.injector = injector
        self.historyStore = historyStore

        capture.onLevel = { [weak self] level in
            Task { @MainActor in
                guard let self else { return }
                self.state.audioLevel = level
                if level > self.state.lastPeakLevel {
                    self.state.lastPeakLevel = level
                }
            }
        }
    }
```

Then add the recording call immediately after the existing `state.lastCleanedText = cleaned` (currently line 175). Find:

```swift
        state.lastCleanedText = cleaned
        AppLog.llm.info("cleanup ok: in=\(transcript.count, privacy: .public) out=\(cleaned.count, privacy: .public) duration=\(self.state.lastCleanupDuration ?? 0, privacy: .public)s")
```

Replace with:

```swift
        state.lastCleanedText = cleaned
        historyStore.record(cleanedText: cleaned)
        AppLog.llm.info("cleanup ok: in=\(transcript.count, privacy: .public) out=\(cleaned.count, privacy: .public) duration=\(self.state.lastCleanupDuration ?? 0, privacy: .public)s")
```

- [ ] **Step 4: Update the production call site so the app still builds**

In `voxline/voxlineApp.swift`, in `AppCoordinator.buildServices(state:settings:)`, find the `CapturePipeline(...)` construction (around line 216):

```swift
        let pipeline = CapturePipeline(
            state: state,
            capture: capture,
            transcriber: transcriber,
            llm: llm,
            modes: router,
            frontmost: frontmost,
            fieldInspector: fieldInspector,
            injector: injector
        )
```

Replace with:

```swift
        let pipeline = CapturePipeline(
            state: state,
            capture: capture,
            transcriber: transcriber,
            llm: llm,
            modes: router,
            frontmost: frontmost,
            fieldInspector: fieldInspector,
            injector: injector,
            historyStore: historyStore
        )
```

The `historyStore` variable doesn't exist yet — we'll add it next. The build will fail here until then.

In the same `AppCoordinator` class body, add a stored property near `var injector: ClipboardInjector?`:

```swift
    var historyStore: DictationHistoryStore?
```

And in `buildServices`, immediately before the `CapturePipeline(...)` construction, instantiate it:

```swift
        let historyStore = DictationHistoryStore()
        self.historyStore = historyStore
```

- [ ] **Step 5: Run tests to verify they pass**

Run:
```bash
cd /Users/toddfredricks/GitHub/voxline && xcodebuild -scheme voxline -destination 'platform=macOS' test -only-testing:voxlineTests/CapturePipelineTests 2>&1 | tail -30
```

Expected: all tests pass, including the three new history tests.

- [ ] **Step 6: Commit**

```bash
cd /Users/toddfredricks/GitHub/voxline && git add voxline/Pipeline/CapturePipeline.swift voxline/voxlineApp.swift voxlineTests/CapturePipelineTests.swift && git commit -m "feat(history): record cleaned text into history store after LLM cleanup"
```

---

## Task 3: Dictation history submenu (rendering + actions)

**Files:**
- Create: `voxline/MenuBar/DictationHistoryMenu.swift`
- Create: `voxlineTests/DictationHistoryMenuTests.swift`
- Modify: `voxline/MenuBar/MenuBarContent.swift`
- Modify: `voxline/voxlineApp.swift` (pass store to `MenuBarContent`)

The submenu and its label-formatting helpers go in a new file. `MenuBarContent` calls into them. Click-to-copy and clear actions live here so `MenuBarContent` stays small.

- [ ] **Step 1: Write the failing tests**

Create `voxlineTests/DictationHistoryMenuTests.swift`:

```swift
import Testing
import Foundation
@testable import voxline

@Suite struct DictationHistoryMenuTests {

    @Test func previewText_collapsesNewlines() {
        let s = "Hello\nthere\tworld"
        #expect(DictationHistoryMenuFormatter.previewText(s, maxChars: 50) == "Hello there world")
    }

    @Test func previewText_collapsesRunsOfWhitespace() {
        let s = "Hello   \n\n  there"
        #expect(DictationHistoryMenuFormatter.previewText(s, maxChars: 50) == "Hello there")
    }

    @Test func previewText_trimsLeadingAndTrailing() {
        let s = "   hello world   "
        #expect(DictationHistoryMenuFormatter.previewText(s, maxChars: 50) == "hello world")
    }

    @Test func previewText_truncatesWithEllipsis() {
        let s = String(repeating: "x", count: 60)
        let out = DictationHistoryMenuFormatter.previewText(s, maxChars: 10)
        #expect(out == "xxxxxxxxxx…")
    }

    @Test func previewText_doesNotTruncateUnderLimit() {
        let s = "short text"
        #expect(DictationHistoryMenuFormatter.previewText(s, maxChars: 50) == "short text")
    }

    @Test func rowLabel_combinesPreviewAndTimestamp() {
        let item = DictationHistoryItem(
            id: UUID(),
            timestamp: Date(timeIntervalSinceNow: -120),
            cleanedText: "Hey team."
        )
        let label = DictationHistoryMenuFormatter.rowLabel(for: item, now: Date())
        // Don't assert exact phrasing — RelativeDateTimeFormatter is locale-dependent —
        // but the preview and a separator must be present.
        #expect(label.hasPrefix("Hey team. · "))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:
```bash
cd /Users/toddfredricks/GitHub/voxline && xcodebuild -scheme voxline -destination 'platform=macOS' test -only-testing:voxlineTests/DictationHistoryMenuTests 2>&1 | tail -30
```

Expected: build failure — `DictationHistoryMenuFormatter` is undefined.

- [ ] **Step 3: Write the formatter + SwiftUI submenu view**

Create `voxline/MenuBar/DictationHistoryMenu.swift`:

```swift
import AppKit
import SwiftUI

/// Pure formatting helpers for history menu rows. Kept separate from the
/// SwiftUI view so they can be unit-tested without spinning up AppKit.
enum DictationHistoryMenuFormatter {

    /// Single-line preview: collapse all whitespace runs (incl. newlines/tabs)
    /// into single spaces, trim, then truncate to `maxChars` with an ellipsis.
    static func previewText(_ text: String, maxChars: Int) -> String {
        let collapsed = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if collapsed.count <= maxChars { return collapsed }
        return String(collapsed.prefix(maxChars)) + "…"
    }

    /// "<preview> · <relative-time>" — "Hey team, just wanted to… · 2m ago".
    static func rowLabel(
        for item: DictationHistoryItem,
        now: Date = Date(),
        maxPreviewChars: Int = 50
    ) -> String {
        let preview = previewText(item.cleanedText, maxChars: maxPreviewChars)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        let when = formatter.localizedString(for: item.timestamp, relativeTo: now)
        return "\(preview) · \(when)"
    }
}

/// "Recent dictations" submenu. Rendered inside `MenuBarContent`.
struct DictationHistoryMenu: View {
    @Bindable var store: DictationHistoryStore
    @Bindable var state: AppState

    var body: some View {
        Menu("Recent dictations") {
            if store.items.isEmpty {
                Button("No recent dictations") {}
                    .disabled(true)
            } else {
                ForEach(store.items) { item in
                    Button(DictationHistoryMenuFormatter.rowLabel(for: item)) {
                        copy(item: item)
                    }
                }
                Divider()
                Button("Clear History") {
                    store.clear()
                }
            }
        }
    }

    private func copy(item: DictationHistoryItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(item.cleanedText, forType: .string)
        state.toastMessage = "Copied"
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if state.toastMessage == "Copied" {
                state.toastMessage = nil
            }
        }
    }
}
```

Note: `state.toastMessage` doesn't exist yet — we add it in Task 4. Build will fail here until then, which is fine because we wire it together in Task 4's step 4.

- [ ] **Step 4: Make `MenuBarContent` render the submenu**

In `voxline/MenuBar/MenuBarContent.swift`, replace the entire file with:

```swift
// voxline/MenuBar/MenuBarContent.swift  (replace contents)
import AppKit
import SwiftUI

struct MenuBarContent: View {
    @Bindable var state: AppState
    @Bindable var historyStore: DictationHistoryStore
    @Environment(\.openSettings) private var openSettings

    var openDebugWindow: () -> Void = {}
    var openAboutWindow: () -> Void = {}
    var tagSettingsWindow: () -> Void = {}

    var body: some View {
        if case .error(_, let message) = state.status {
            Text(message)
                .foregroundStyle(.red)
            Divider()
        }

        if case .downloadingModel(let p) = state.status {
            Text("Downloading model — \(Int(p * 100))%")
                .foregroundStyle(.secondary)
            Divider()
        }

        Button(state.hotkeyEnabled ? "Pause Voxline" : "Resume Voxline") {
            state.hotkeyEnabled.toggle()
        }

        Divider()

        DictationHistoryMenu(store: historyStore, state: state)

        Divider()

        Button("Settings…") {
            openSettings()
            NSApp.activate()
            tagSettingsWindow()
        }
        .keyboardShortcut(",")

        #if DEBUG
        Divider()
        Button("Debug…") { openDebugWindow() }
        #endif

        Divider()

        Button("About Voxline") { openAboutWindow() }

        Divider()

        Button("Quit Voxline") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
```

- [ ] **Step 5: Wire `historyStore` into `voxlineApp.swift`**

In `voxline/voxlineApp.swift`, the `AppDelegate` already lives at the composition root. The `historyStore` is currently owned by `AppCoordinator` (set in Task 2). We need it on `AppDelegate` instead so the SwiftUI body can read it. Move it.

Remove the `var historyStore: DictationHistoryStore?` line and the `let historyStore = DictationHistoryStore()` / `self.historyStore = historyStore` lines from `AppCoordinator` (added in Task 2).

In `AppDelegate`, add (after `let appState = AppState()`):

```swift
    let historyStore = DictationHistoryStore()
```

In `AppCoordinator.buildServices(state:settings:)`, change the constructor to accept a `historyStore` parameter. Replace the signature:

```swift
    private func buildServices(state: AppState, settings: AppSettings) {
```

with:

```swift
    private func buildServices(state: AppState, settings: AppSettings, historyStore: DictationHistoryStore) {
```

The parameter then flows through to `CapturePipeline(...)` (which already takes `historyStore:` from Task 2).

Update the two callers of `buildServices` inside `AppCoordinator` — `startWizardThenApp` and `startApp` — to take a `historyStore` parameter too:

```swift
    private func startWizardThenApp(state: AppState, settings: AppSettings, historyStore: DictationHistoryStore) {
        buildServices(state: state, settings: settings, historyStore: historyStore)
        // ... rest unchanged
    }

    private func startApp(state: AppState, settings: AppSettings, historyStore: DictationHistoryStore) {
        buildServices(state: state, settings: settings, historyStore: historyStore)
        // ... rest unchanged
    }
```

Update `startIfNeeded(state:)` to accept and forward the store:

```swift
    func startIfNeeded(state: AppState, historyStore: DictationHistoryStore) {
        guard !didStart else { return }
        didStart = true
        self.appState = state

        let settings = AppSettings()
        if !settings.hasCompletedFirstRun {
            startWizardThenApp(state: state, settings: settings, historyStore: historyStore)
        } else {
            startApp(state: state, settings: settings, historyStore: historyStore)
        }
    }
```

And update the only caller in `AppDelegate.applicationDidFinishLaunching`:

```swift
    func applicationDidFinishLaunching(_ notification: Notification) {
        windowVisibility.start()
        coordinator.startIfNeeded(state: appState, historyStore: historyStore)
    }
```

Finally, in `voxlineApp`'s `body` scene, pass `historyStore` to `MenuBarContent`:

```swift
        MenuBarExtra {
            MenuBarContent(
                state: delegate.appState,
                historyStore: delegate.historyStore,
                openDebugWindow: {
                    delegate.debugWindow.show(
                        state: delegate.appState,
                        coordinator: delegate.coordinator
                    )
                },
                openAboutWindow: {
                    delegate.showAboutWindow()
                },
                tagSettingsWindow: {
                    delegate.tagSettingsWindowSoon()
                }
            )
        } label: {
            MenuBarLabel(state: delegate.appState)
        }
        .menuBarExtraStyle(.menu)
```

- [ ] **Step 6: Run formatter tests**

The submenu view body references `state.toastMessage` — that field doesn't exist yet. Skip the full app build for now and run only the formatter unit tests, which don't depend on the SwiftUI view:

```bash
cd /Users/toddfredricks/GitHub/voxline && xcodebuild -scheme voxline -destination 'platform=macOS' test -only-testing:voxlineTests/DictationHistoryMenuTests 2>&1 | tail -30
```

Expected: all formatter tests pass. The app target will fail to build until Task 4 adds `toastMessage`. That's expected — Task 4 finishes the wiring.

- [ ] **Step 7: Commit**

```bash
cd /Users/toddfredricks/GitHub/voxline && git add voxline/MenuBar/DictationHistoryMenu.swift voxline/MenuBar/MenuBarContent.swift voxline/voxlineApp.swift voxlineTests/DictationHistoryMenuTests.swift && git commit -m "feat(history): add Recent dictations submenu with copy + clear actions"
```

---

## Task 4: Toast feedback via the recording pill

**Files:**
- Modify: `voxline/AppState.swift` (add `toastMessage`)
- Modify: `voxline/UI/RecordingPillView.swift` (render toast case)
- Modify: `voxline/UI/RecordingPillWindow.swift` (show window when toast set)

Toast appears in the existing pill window — re-using the same surface keeps the visual language consistent and avoids a new NSPanel. Pill repositions to current mouse on each show; clicking a menu row means mouse is at the menu bar, so the toast lands near the menu — acceptable.

- [ ] **Step 1: Add `toastMessage` to `AppState`**

In `voxline/AppState.swift`, add a new stored property after `var hotkeyEnabled: Bool = true` (line 47):

```swift
    /// Transient feedback string ("Copied" after a history-row click), or nil.
    /// `RecordingPillWindow` shows the pill while this is set. The setter that
    /// flips this on is also responsible for clearing it after a short delay.
    var toastMessage: String?
```

- [ ] **Step 2: Render a toast case in `RecordingPillView`**

In `voxline/UI/RecordingPillView.swift`, modify the `body` to handle a `toastMessage` even when status is `.idle`. Replace the entire `body` property with:

```swift
    var body: some View {
        HStack(spacing: 10) {
            switch state.status {
            case .recording:
                WaveformBars(level: state.audioLevel)
                Text(elapsed)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .monospacedDigit()
            case .thinking:
                ProgressView()
                    .controlSize(.small)
                Text("Transcribing…")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
            default:
                if let toast = state.toastMessage {
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
        .frame(width: 140, height: 32)
    }
```

- [ ] **Step 3: Show the pill window when `toastMessage` is set**

In `voxline/UI/RecordingPillWindow.swift`, modify `updateVisibility(state:)` so the toast counts as a reason to show the window. Replace the method body with:

```swift
    func updateVisibility(state: AppState) {
        guard let panel else { return }
        let recordingOrThinking: Bool = {
            switch state.status {
            case .recording, .thinking: return true
            default: return false
            }
        }()
        let hasToast = (state.toastMessage != nil)
        if recordingOrThinking || hasToast {
            if !panel.isVisible {
                repositionNearMouse(panel: panel)
                panel.orderFrontRegardless()
            }
        } else {
            panel.orderOut(nil)
        }
    }
```

- [ ] **Step 4: Make the coordinator observe `toastMessage` so the pill shows/hides**

The pill's visibility today is driven by `AppCoordinator` calling `pillWindow?.updateVisibility(state:)` after hotkey start/finalize callbacks. Setting `state.toastMessage` from a menu click doesn't go through those callbacks, so the pill won't auto-show.

In `voxline/voxlineApp.swift`, find `installHotkey(state:settings:)` and just before the `startPermissionAndStateLoop(state: state)` call near the end, add an observer that re-renders pill visibility whenever `toastMessage` flips:

```swift
        observeToastChanges(state: state)
```

Then add a new helper method on `AppCoordinator` near `observeHotkeyEnabledChanges`:

```swift
    /// Re-runs `pillWindow.updateVisibility` whenever `state.toastMessage`
    /// changes, so a history-row click that sets a "Copied" toast pops the
    /// pill open (and clears it on the next change, which is the auto-nil
    /// after 1.2s).
    private func observeToastChanges(state: AppState) {
        withObservationTracking {
            _ = state.toastMessage
        } onChange: { [weak self, weak state] in
            Task { @MainActor in
                guard let self, let state else { return }
                self.pillWindow?.updateVisibility(state: state)
                self.observeToastChanges(state: state)
            }
        }
    }
```

(`pillWindow` is `private var pillWindow: RecordingPillWindow?` so the helper compiles.)

- [ ] **Step 5: Build and run the full test suite**

Run:
```bash
cd /Users/toddfredricks/GitHub/voxline && xcodebuild -scheme voxline -destination 'platform=macOS' test 2>&1 | tail -40
```

Expected: clean build, all tests pass — including the existing `DictationHistoryStoreTests`, `DictationHistoryMenuTests`, and `CapturePipelineTests` history additions.

- [ ] **Step 6: Manual smoke**

```bash
cd /Users/toddfredricks/GitHub/voxline && xcodebuild -scheme voxline -destination 'platform=macOS' -configuration Debug build 2>&1 | tail -10
```

Launch the app from Xcode (Cmd+R), then:

1. Dictate three short phrases ("first one", "second one", "third one"). Confirm each pastes normally.
2. Open the menu bar → hover "Recent dictations". Confirm the submenu lists all three, newest first ("third one… · just now" at the top), each with a relative timestamp.
3. Click the middle row. Confirm:
   - The "Copied" pill briefly appears (≈1.2s).
   - The clipboard contains the row's full cleaned text (paste into TextEdit to verify).
4. Click "Clear History". Confirm the submenu now shows "No recent dictations".
5. Quit and relaunch. Dictate one phrase, quit again, relaunch. Confirm the submenu still shows that phrase.

Report any deviations rather than auto-fixing.

- [ ] **Step 7: Commit**

```bash
cd /Users/toddfredricks/GitHub/voxline && git add voxline/AppState.swift voxline/UI/RecordingPillView.swift voxline/UI/RecordingPillWindow.swift voxline/voxlineApp.swift && git commit -m "feat(history): show 'Copied' toast in pill window when a history row is clicked"
```

---

## Task 5: Mark feature done in `docs/features.md`

**Files:**
- Modify: `docs/features.md`

- [ ] **Step 1: Flip the checkbox**

In `docs/features.md`, change line 16 from:

```
16. [ ] **Dictation history** — Keeps recent dictations so users can recover text, rerun transformations, or copy previous outputs.
```

to:

```
16. [x] **Dictation history** — Keeps the last 10 cleaned dictations in a menu-bar submenu; click a row to copy it to the clipboard. Re-running transformations is deferred (would require storing the raw transcript).
```

- [ ] **Step 2: Commit**

```bash
cd /Users/toddfredricks/GitHub/voxline && git add docs/features.md && git commit -m "docs(features): mark dictation history (#16) as done"
```

---

## Self-Review Notes

- **Spec coverage:** All sections of the design doc map to tasks. Task 1 covers the store + persistence + tests. Task 2 covers the pipeline integration test and the pipeline change. Task 3 covers the submenu (preview format, relative timestamp, empty state, clear). Task 4 covers the toast. Task 5 updates features.md.
- **Type consistency:** `DictationHistoryStore.record(cleanedText:)` and `clear()` signatures match throughout. `DictationHistoryItem` properties (`id`, `timestamp`, `cleanedText`) match throughout.
- **Test isolation:** All tests use per-test `UserDefaults(suiteName:)` to avoid touching the user's real defaults — matches the existing `AppSettingsTests` pattern.
- **Composition root:** `historyStore` lives on `AppDelegate` (long-lived, single instance) and is passed through `AppCoordinator.startIfNeeded` so both the pipeline and the menu read the same store.
- **Build ordering:** Task 3 deliberately leaves the app target failing to build (it references `state.toastMessage`) until Task 4 step 1 adds the field. Task 4 finishes the wiring and runs the full test suite + manual smoke.
