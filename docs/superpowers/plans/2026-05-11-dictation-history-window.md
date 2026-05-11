# Dictation History Window Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the menu-bar "Recent dictations" submenu with a standalone window that shows Time/Mode/App/Preview columns, bump capacity from 10 to 25, and record the resolved mode and frontmost app for every cleaned dictation.

**Architecture:** Extend `DictationHistoryItem` with four optional fields, widen `DictationHistoryStore.record` to take a `Mode` and `CapturedContext`, build a SwiftUI `HistoryView` (`Table`) hosted by a lightweight `HistoryWindowController` (`NSWindow` + `NSHostingController`, same pattern as `DebugWindowController` and `AboutWindowController`). After the window is wired, delete the old `DictationHistoryMenu` and its tests.

**Tech Stack:** Swift 5.9, SwiftUI, AppKit, Swift Testing (`@Test`), `UserDefaults` persistence, Xcode synchronized-group project (new `.swift` files dropped under `voxline/` are picked up automatically).

**Spec:** [docs/superpowers/specs/2026-05-11-dictation-history-window-design.md](../specs/2026-05-11-dictation-history-window-design.md)

---

## File Map

**Modify:**
- `voxline/Storage/DictationHistoryStore.swift` — add 4 optional fields to the item; widen `record` signature; bump cap to 25.
- `voxline/Pipeline/CapturePipeline.swift:194` — pass `mode` + `context` to `historyStore.record(...)`.
- `voxline/MenuBar/MenuBarContent.swift` — swap the submenu for a "Show history…" button; add `openHistoryWindow` closure prop.
- `voxline/voxlineApp.swift` — instantiate `HistoryWindowController`; wire `openHistoryWindow` into `MenuBarContent`.
- `voxlineTests/DictationHistoryStoreTests.swift` — update cap test (25), add mode/app capture tests, add old-schema backwards-compat test.
- `voxlineTests/CapturePipelineTests.swift` — extend existing history assertion to cover the four new fields.
- `docs/insertion-smoke-matrix.md` — add History window section.

**Create:**
- `voxline/UI/HistoryView.swift` — SwiftUI `Table` view + private `HistoryViewFormatter` enum (including `previewText`).
- `voxline/UI/HistoryWindowController.swift` — `NSWindow` + `NSHostingController` wrapper.
- `voxlineTests/HistoryViewFormatterTests.swift` — covers `previewText` (the cases migrated from `DictationHistoryMenuFormatter`).

**Delete:**
- `voxline/MenuBar/DictationHistoryMenu.swift` — replaced by the window.
- `voxlineTests/DictationHistoryMenuTests.swift` — `rowLabel` tests are obsolete; `previewText` cases migrate to `HistoryViewFormatterTests`.

---

## Task 1: Extend `DictationHistoryItem` schema (backwards-compat)

**Files:**
- Modify: `voxline/Storage/DictationHistoryStore.swift`
- Modify: `voxlineTests/DictationHistoryStoreTests.swift`

Adds four optional fields so new rows can carry mode + app metadata. `record(cleanedText:)` still exists — the new fields default to nil. Build stays green and the menu UI keeps working. The next task widens `record`.

- [ ] **Step 1: Write the failing test for backwards-compat decode**

Append to `voxlineTests/DictationHistoryStoreTests.swift` (just before the closing `}` of the `@Suite struct`):

```swift
@Test func loads_old_schema_json_with_nil_new_fields() throws {
    // The 1.0 history shape: only id/timestamp/cleanedText. Existing users
    // upgrading must keep their history; the new fields decode as nil.
    let suite = UserDefaults(suiteName: "voxline.history.test.\(UUID().uuidString)")!
    defer { suite.removePersistentDomain(forName: "voxline.history.test") }

    let oldJSON = #"""
    [
      {"id":"00000000-0000-0000-0000-000000000001","timestamp":770000000.0,"cleanedText":"hello"},
      {"id":"00000000-0000-0000-0000-000000000002","timestamp":770000001.0,"cleanedText":"world"}
    ]
    """#.data(using: .utf8)!
    suite.set(oldJSON, forKey: DictationHistoryStore.key)

    let store = DictationHistoryStore(defaults: suite)

    #expect(store.items.count == 2)
    let first = try #require(store.items.first)
    #expect(first.cleanedText == "hello")
    #expect(first.modeDisplayName == nil)
    #expect(first.modeBundleID == nil)
    #expect(first.appName == nil)
    #expect(first.appBundleID == nil)
}
```

- [ ] **Step 2: Run the test and verify it fails to compile**

Run: `xcodebuild -scheme voxline -destination 'platform=macOS,arch=arm64' test -only-testing:voxlineTests/DictationHistoryStoreTests/loads_old_schema_json_with_nil_new_fields 2>&1 | tail -20`
Expected: build error — `Value of type 'DictationHistoryItem' has no member 'modeDisplayName'`.

- [ ] **Step 3: Add the four optional fields to `DictationHistoryItem`**

Edit `voxline/Storage/DictationHistoryStore.swift`. Replace the existing struct definition (around lines 8–18) with:

```swift
struct DictationHistoryItem: Codable, Identifiable, Equatable {
    let id: UUID
    let timestamp: Date
    let cleanedText: String
    /// Display name of the resolved Mode at capture time (e.g. "Slack"). Nil
    /// only for rows persisted before mode capture existed.
    let modeDisplayName: String?
    /// Bundle ID the resolved Mode is keyed on. `"*"` for the wildcard.
    let modeBundleID: String?
    /// Localized name of the frontmost app, from `CapturedContext.appName`.
    /// Nil when AX denied capture or no app was frontmost.
    let appName: String?
    /// Bundle ID of the frontmost app, from `CapturedContext.bundleID`.
    let appBundleID: String?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        cleanedText: String,
        modeDisplayName: String? = nil,
        modeBundleID: String? = nil,
        appName: String? = nil,
        appBundleID: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.cleanedText = cleanedText
        self.modeDisplayName = modeDisplayName
        self.modeBundleID = modeBundleID
        self.appName = appName
        self.appBundleID = appBundleID
    }
}
```

The synthesized `Codable` conformance handles `decodeIfPresent` automatically for optional `let` properties, which is what makes the old-schema JSON load.

- [ ] **Step 4: Run the new test and verify it passes**

Run: `xcodebuild -scheme voxline -destination 'platform=macOS,arch=arm64' test -only-testing:voxlineTests/DictationHistoryStoreTests/loads_old_schema_json_with_nil_new_fields 2>&1 | tail -10`
Expected: `Test loads_old_schema_json_with_nil_new_fields() passed`.

- [ ] **Step 5: Run the full store test suite**

Run: `xcodebuild -scheme voxline -destination 'platform=macOS,arch=arm64' test -only-testing:voxlineTests/DictationHistoryStoreTests 2>&1 | tail -20`
Expected: all tests pass — none of the existing tests reference the new fields, so they continue to construct items via the existing init (the new init's default-nil parameters preserve the old call shape).

- [ ] **Step 6: Build the full target to make sure no consumer broke**

Run: `xcodebuild -scheme voxline -destination 'platform=macOS,arch=arm64' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`. `CapturePipeline` still calls `record(cleanedText:)`, which still exists.

- [ ] **Step 7: Commit**

```bash
git add voxline/Storage/DictationHistoryStore.swift voxlineTests/DictationHistoryStoreTests.swift
git commit -m "feat(history): add optional mode/app fields to DictationHistoryItem (#16)"
```

---

## Task 2: Widen `DictationHistoryStore.record` + bump cap to 25

**Files:**
- Modify: `voxline/Storage/DictationHistoryStore.swift`
- Modify: `voxline/Pipeline/CapturePipeline.swift`
- Modify: `voxlineTests/DictationHistoryStoreTests.swift`
- Modify: `voxlineTests/CapturePipelineTests.swift`

Switches the `record` signature to accept `mode` and `context`, raises `maxItems` from 10 to 25, and updates the only call site in the pipeline.

- [ ] **Step 1: Write the failing test for mode + app capture**

In `voxlineTests/DictationHistoryStoreTests.swift`, add these three tests near the existing `record_*` tests:

```swift
@Test func record_captures_mode_fields() {
    let suite = UserDefaults(suiteName: "voxline.history.test.\(UUID().uuidString)")!
    defer { suite.removePersistentDomain(forName: "voxline.history.test") }
    let store = DictationHistoryStore(defaults: suite)

    let mode = Mode(
        bundleID: "com.test.app",
        displayName: "Test",
        prompt: "p",
        model: nil,
        temperature: nil
    )
    store.record(cleanedText: "hi", mode: mode, context: .empty)

    let item = try! #require(store.items.first)
    #expect(item.modeDisplayName == "Test")
    #expect(item.modeBundleID == "com.test.app")
}

@Test func record_captures_app_fields_from_context() {
    let suite = UserDefaults(suiteName: "voxline.history.test.\(UUID().uuidString)")!
    defer { suite.removePersistentDomain(forName: "voxline.history.test") }
    let store = DictationHistoryStore(defaults: suite)

    var ctx = CapturedContext.empty
    ctx.appName = "Slack"
    ctx.bundleID = "com.tinyspeck.slackmacgap"
    let mode = Mode(bundleID: "*", displayName: "Default", prompt: "p", model: nil, temperature: nil)
    store.record(cleanedText: "hello team", mode: mode, context: ctx)

    let item = try! #require(store.items.first)
    #expect(item.appName == "Slack")
    #expect(item.appBundleID == "com.tinyspeck.slackmacgap")
}

@Test func record_empty_context_stores_nil_app_fields() {
    let suite = UserDefaults(suiteName: "voxline.history.test.\(UUID().uuidString)")!
    defer { suite.removePersistentDomain(forName: "voxline.history.test") }
    let store = DictationHistoryStore(defaults: suite)

    let mode = Mode(bundleID: "*", displayName: "Default", prompt: "p", model: nil, temperature: nil)
    store.record(cleanedText: "x", mode: mode, context: .empty)

    let item = try! #require(store.items.first)
    #expect(item.appName == nil)
    #expect(item.appBundleID == nil)
}
```

- [ ] **Step 2: Update the existing cap test to expect 25 and any signature changes**

Find the existing cap-test in `voxlineTests/DictationHistoryStoreTests.swift` (it asserts the 10-cap). Replace its body so it records 30 items and asserts 25 remain. If the existing test calls `store.record(cleanedText:)`, update those call sites to pass the new arguments. The simplest pattern: build a single fake mode and pass `CapturedContext.empty` for every call.

```swift
@Test func record_caps_at_25_dropping_oldest() {
    let suite = UserDefaults(suiteName: "voxline.history.test.\(UUID().uuidString)")!
    defer { suite.removePersistentDomain(forName: "voxline.history.test") }
    let store = DictationHistoryStore(defaults: suite)
    let mode = Mode(bundleID: "*", displayName: "Default", prompt: "p", model: nil, temperature: nil)

    for i in 0..<30 {
        store.record(cleanedText: "entry \(i)", mode: mode, context: .empty)
    }

    #expect(store.items.count == 25)
    // Newest first: "entry 29" wins; "entry 0..4" should have been evicted.
    #expect(store.items.first?.cleanedText == "entry 29")
    #expect(store.items.contains(where: { $0.cleanedText == "entry 4" }) == false)
    #expect(store.items.contains(where: { $0.cleanedText == "entry 5" }) == true)
}
```

Also scan the rest of the test file for any other `store.record(cleanedText:)` call that omits `mode:context:` and update them to the new shape (use the same throwaway mode + `.empty` context). The whitespace-only test, persistence round-trip, etc. all need this update.

- [ ] **Step 3: Run the new tests to verify they fail**

Run: `xcodebuild -scheme voxline -destination 'platform=macOS,arch=arm64' test -only-testing:voxlineTests/DictationHistoryStoreTests 2>&1 | tail -20`
Expected: compile failures — `Extra argument 'mode' in call`.

- [ ] **Step 4: Widen the `record` signature and bump the cap**

Edit `voxline/Storage/DictationHistoryStore.swift`:

```swift
private static let maxItems = 25   // was 10
```

Replace the existing `record(cleanedText:)` body with:

```swift
/// Prepend a new entry for a successful dictation. Pulls the resolved mode
/// and frontmost-app fields so the history window can show context per row.
/// Whitespace-only text is ignored. Caps at 25 by dropping the oldest entries.
func record(cleanedText: String, mode: Mode, context: CapturedContext) {
    guard !cleanedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    let item = DictationHistoryItem(
        cleanedText: cleanedText,
        modeDisplayName: mode.displayName,
        modeBundleID: mode.bundleID,
        appName: context.appName,
        appBundleID: context.bundleID
    )
    var next = [item] + items
    if next.count > Self.maxItems {
        next = Array(next.prefix(Self.maxItems))
    }
    items = next
    persist()
}
```

- [ ] **Step 5: Update the pipeline call site**

Edit `voxline/Pipeline/CapturePipeline.swift` line 194. Change:

```swift
historyStore.record(cleanedText: cleaned)
```

to:

```swift
historyStore.record(cleanedText: cleaned, mode: mode, context: context)
```

Both `mode` and `context` are already local variables in scope at this point (declared earlier in `recordingFinished`).

- [ ] **Step 6: Update `CapturePipelineTests` to assert the new fields**

Open `voxlineTests/CapturePipelineTests.swift`. Find the existing assertion that checks history was recorded after a successful cleanup (search for `historyStore.items` or `DictationHistoryStore`). Extend that test to also assert mode and app fields. Example pattern (adapt to the existing test names/structure):

```swift
let item = try #require(historyStore.items.first)
#expect(item.cleanedText == "cleaned-output")
#expect(item.modeDisplayName == "TestMode")          // displayName of the fake Mode wired in
#expect(item.modeBundleID == "com.test.bundle")      // bundleID of the fake Mode
#expect(item.appName == "TestApp")                   // CapturedContext.appName set by the fake context service
#expect(item.appBundleID == "com.test.bundle")       // CapturedContext.bundleID
```

If the existing test uses `.empty` context and a generic Mode, set the fake Mode's `displayName`/`bundleID` and the fake context's `appName`/`bundleID` to known values so the new assertions can match exactly. Check the existing fakes (`FakeModeResolving` / `FakeContextCaptureService` or similar) and seed them with deterministic values for this test only.

- [ ] **Step 7: Run all DictationHistoryStore tests**

Run: `xcodebuild -scheme voxline -destination 'platform=macOS,arch=arm64' test -only-testing:voxlineTests/DictationHistoryStoreTests 2>&1 | tail -20`
Expected: all DictationHistoryStore tests pass (including the four new ones + the cap test).

- [ ] **Step 8: Run the pipeline tests**

Run: `xcodebuild -scheme voxline -destination 'platform=macOS,arch=arm64' test -only-testing:voxlineTests/CapturePipelineTests 2>&1 | tail -20`
Expected: all pipeline tests pass.

- [ ] **Step 9: Run the full test suite**

Run: `xcodebuild -scheme voxline -destination 'platform=macOS,arch=arm64' test 2>&1 | tail -10`
Expected: `** TEST SUCCEEDED **` with all tests passing.

- [ ] **Step 10: Commit**

```bash
git add voxline/Storage/DictationHistoryStore.swift \
        voxline/Pipeline/CapturePipeline.swift \
        voxlineTests/DictationHistoryStoreTests.swift \
        voxlineTests/CapturePipelineTests.swift
git commit -m "feat(history): capture mode + app fields; raise cap to 25 (#16)"
```

---

## Task 3: Create `HistoryViewFormatter` + tests

**Files:**
- Create: `voxlineTests/HistoryViewFormatterTests.swift`
- Create: `voxline/UI/HistoryView.swift` (formatter only in this task; the view body comes in Task 4)

Migrates `previewText` from the soon-to-be-deleted `DictationHistoryMenuFormatter` into a dedicated formatter for the table's Preview column. The view file is created in this task but the body is a placeholder; Task 4 fills it in. Doing this in two tasks keeps each commit narrow.

- [ ] **Step 1: Write the failing tests**

Create `voxlineTests/HistoryViewFormatterTests.swift`:

```swift
import Testing
@testable import voxline

@Suite struct HistoryViewFormatterTests {

    @Test func preview_returns_short_text_unchanged() {
        #expect(HistoryViewFormatter.previewText("hello", maxChars: 80) == "hello")
    }

    @Test func preview_collapses_whitespace_runs_into_single_spaces() {
        #expect(HistoryViewFormatter.previewText("a\n\nb\tc   d", maxChars: 80) == "a b c d")
    }

    @Test func preview_truncates_with_ellipsis() {
        let long = String(repeating: "x", count: 100)
        let out = HistoryViewFormatter.previewText(long, maxChars: 10)
        #expect(out == String(repeating: "x", count: 10) + "…")
    }

    @Test func preview_trims_surrounding_whitespace() {
        #expect(HistoryViewFormatter.previewText("   hello world   ", maxChars: 80) == "hello world")
    }

    @Test func preview_empty_string_returns_empty() {
        #expect(HistoryViewFormatter.previewText("", maxChars: 80) == "")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild -scheme voxline -destination 'platform=macOS,arch=arm64' test -only-testing:voxlineTests/HistoryViewFormatterTests 2>&1 | tail -10`
Expected: compile error — `Cannot find 'HistoryViewFormatter' in scope`.

- [ ] **Step 3: Create the view file with the formatter (placeholder view body)**

Create `voxline/UI/HistoryView.swift`:

```swift
// voxline/UI/HistoryView.swift
//
// Standalone window listing recent cleaned dictations with Time / Mode /
// App / Preview columns. Click a row to copy that entry's text. Replaces
// the menu-bar submenu — the latter could not surface the resolved mode
// for each row without exploding in size.

import AppKit
import SwiftUI

/// Pure-string formatting helpers for the history table's Preview column.
/// Kept separate from the view so it can be unit-tested without spinning up
/// SwiftUI.
enum HistoryViewFormatter {

    /// Single-line preview: collapse all whitespace runs (including newlines
    /// and tabs) into single spaces, trim, then truncate to `maxChars` with
    /// an ellipsis.
    static func previewText(_ text: String, maxChars: Int) -> String {
        let collapsed = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if collapsed.count <= maxChars { return collapsed }
        return String(collapsed.prefix(maxChars)) + "…"
    }
}

/// Placeholder body — filled in by Task 4. Defined here so the file exists
/// in the project and the formatter is reachable from the test target.
struct HistoryView: View {
    @Bindable var store: DictationHistoryStore
    @Bindable var state: AppState

    var body: some View {
        EmptyView()
    }
}
```

- [ ] **Step 4: Run the formatter tests to verify they pass**

Run: `xcodebuild -scheme voxline -destination 'platform=macOS,arch=arm64' test -only-testing:voxlineTests/HistoryViewFormatterTests 2>&1 | tail -10`
Expected: all five tests pass.

- [ ] **Step 5: Build the full target**

Run: `xcodebuild -scheme voxline -destination 'platform=macOS,arch=arm64' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`. The old `DictationHistoryMenu.swift` and its formatter still exist and still compile — they are unaffected by the new file.

- [ ] **Step 6: Commit**

```bash
git add voxline/UI/HistoryView.swift voxlineTests/HistoryViewFormatterTests.swift
git commit -m "feat(history): add HistoryViewFormatter for table preview column (#16)"
```

---

## Task 4: Implement the `HistoryView` body

**Files:**
- Modify: `voxline/UI/HistoryView.swift`

Replaces the `EmptyView` placeholder with the real `Table` body: four columns, click-to-copy via `Table` selection-binding (cleared immediately so re-clicking the same row works), tooltip per cell, Clear-history toolbar button, empty-state placeholder.

- [ ] **Step 1: Replace the view body**

Edit `voxline/UI/HistoryView.swift`. Replace the entire `struct HistoryView: View { ... }` block with:

```swift
struct HistoryView: View {
    @Bindable var store: DictationHistoryStore
    @Bindable var state: AppState

    /// Selection-bound row click. We immediately copy and clear the selection
    /// so a second click on the same row still fires. Using `selection:` is
    /// the only first-class row-click affordance SwiftUI's `Table` exposes
    /// on macOS; `onTapGesture` per cell wouldn't fire on whitespace inside
    /// a row.
    @State private var selectedID: DictationHistoryItem.ID? = nil

    var body: some View {
        Group {
            if store.items.isEmpty {
                emptyState
            } else {
                table
            }
        }
        .frame(minWidth: 560, minHeight: 320)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Clear history") { store.clear() }
                    .disabled(store.items.isEmpty)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("No recent dictations.")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Hold your push-to-talk hotkey to dictate. Cleaned dictations appear here.")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var table: some View {
        Table(store.items, selection: $selectedID) {
            TableColumn("Time") { item in
                Text(Self.relativeTime(item.timestamp))
                    .help(Self.tooltip(item))
            }
            .width(min: 80, ideal: 100)

            TableColumn("Mode") { item in
                Text(item.modeDisplayName ?? "—")
                    .help(Self.tooltip(item))
            }
            .width(min: 80, ideal: 110)

            TableColumn("App") { item in
                Text(item.appName ?? item.appBundleID ?? "—")
                    .help(Self.tooltip(item))
            }
            .width(min: 100, ideal: 140)

            TableColumn("Preview") { item in
                Text(HistoryViewFormatter.previewText(item.cleanedText, maxChars: 120))
                    .help(Self.tooltip(item))
            }
        }
        .onChange(of: selectedID) { _, newID in
            guard let id = newID,
                  let item = store.items.first(where: { $0.id == id })
            else { return }
            copy(item)
            selectedID = nil
        }
    }

    private func copy(_ item: DictationHistoryItem) {
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

    private static func relativeTime(_ when: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: when, relativeTo: Date())
    }

    private static func tooltip(_ item: DictationHistoryItem) -> String {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .medium
        return "\(df.string(from: item.timestamp))\n\n\(item.cleanedText)"
    }
}
```

- [ ] **Step 2: Build the full target**

Run: `xcodebuild -scheme voxline -destination 'platform=macOS,arch=arm64' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`. The view is still unreferenced by anything outside its own file.

- [ ] **Step 3: Run the full test suite to make sure nothing regressed**

Run: `xcodebuild -scheme voxline -destination 'platform=macOS,arch=arm64' test 2>&1 | tail -10`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add voxline/UI/HistoryView.swift
git commit -m "feat(history): implement HistoryView table body (#16)"
```

---

## Task 5: Create `HistoryWindowController`

**Files:**
- Create: `voxline/UI/HistoryWindowController.swift`

Lightweight `NSWindow` wrapper following the existing `AboutWindowController` pattern. Lazy creation, `makeKeyAndOrderFront` on subsequent calls.

- [ ] **Step 1: Create the file**

Create `voxline/UI/HistoryWindowController.swift`:

```swift
// voxline/UI/HistoryWindowController.swift
//
// Hosts HistoryView in a regular activating NSWindow. Same pattern as
// AboutWindowController and DebugWindowController: lazy-create on first
// show, just bring forward on subsequent calls.

import AppKit
import SwiftUI

@MainActor
final class HistoryWindowController {
    private var window: NSWindow?

    func show(store: DictationHistoryStore, state: AppState) {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let host = NSHostingController(rootView: HistoryView(store: store, state: state))
        let win = NSWindow(contentViewController: host)
        win.title = "Voxline History"
        win.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        win.setContentSize(NSSize(width: 720, height: 480))
        win.isReleasedWhenClosed = false
        win.center()
        win.identifier = WindowVisibilityCoordinator.dockworthyIdentifier
        self.window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}
```

- [ ] **Step 2: Build the full target**

Run: `xcodebuild -scheme voxline -destination 'platform=macOS,arch=arm64' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`. The controller is unreferenced; it will be wired in Task 6.

- [ ] **Step 3: Commit**

```bash
git add voxline/UI/HistoryWindowController.swift
git commit -m "feat(history): add HistoryWindowController (#16)"
```

---

## Task 6: Wire menu bar + voxlineApp; delete old menu

**Files:**
- Modify: `voxline/MenuBar/MenuBarContent.swift`
- Modify: `voxline/voxlineApp.swift`
- Delete: `voxline/MenuBar/DictationHistoryMenu.swift`
- Delete: `voxlineTests/DictationHistoryMenuTests.swift`

Cuts over the menu bar from the submenu to a single "Show history…" button and removes the now-orphaned menu file and its tests in the same commit so the tree never carries dead code.

- [ ] **Step 1: Add `openHistoryWindow` closure to `MenuBarContent`**

Edit `voxline/MenuBar/MenuBarContent.swift`. Add a new closure property next to the existing `openDebugWindow` / `openAboutWindow`:

```swift
var openHistoryWindow: () -> Void = {}
```

Then replace the line `DictationHistoryMenu(store: historyStore, state: state)` with:

```swift
Button("Show history…") { openHistoryWindow() }
```

The full updated body section around the submenu should read:

```swift
Divider()

Button("Show history…") { openHistoryWindow() }

Divider()

Button("Settings…") {
    ...
```

Note: `historyStore` is still passed into `MenuBarContent` so the binding doesn't change at the call site — but the menu no longer reads it directly. Leave the `@Bindable var historyStore: DictationHistoryStore` property in place; it's used to keep the menu in sync with the latest items count for any future per-row indicator. (If the engineer wants to remove the unused binding, that's a separate cleanup; the spec is silent on it.)

Actually: if the binding is genuinely unused after this change, Swift will not warn but it's dead code. **Remove it.** Delete the `@Bindable var historyStore: ...` line from `MenuBarContent` and any call-site argument that passes `historyStore: delegate.historyStore` into the view (in `voxlineApp.swift`).

- [ ] **Step 2: Wire `HistoryWindowController` into `voxlineApp.swift`**

Edit `voxline/voxlineApp.swift`. Near the existing `let debugWindow = DebugWindowController()` (around line 74), add:

```swift
let historyWindow = HistoryWindowController()
```

Find the call site that constructs `MenuBarContent` (around line 28–35 of the same file). Add `openHistoryWindow:` to the argument list and remove `historyStore:` if you also removed the binding in Step 1:

```swift
MenuBarContent(
    state: appState,
    openDebugWindow: { delegate.debugWindow.show(state: appState, coordinator: delegate.coordinator) },
    openAboutWindow: { delegate.aboutWindow.show(env: ...) },
    openHistoryWindow: { delegate.historyWindow.show(store: delegate.historyStore, state: appState) },
    tagSettingsWindow: { ... }
)
```

Use the existing closures (`openDebugWindow`, `openAboutWindow`) as the template for capture semantics — match them exactly.

- [ ] **Step 3: Delete the old menu file**

```bash
git rm voxline/MenuBar/DictationHistoryMenu.swift
```

- [ ] **Step 4: Delete the old menu tests**

```bash
git rm voxlineTests/DictationHistoryMenuTests.swift
```

The `previewText` cases live in `HistoryViewFormatterTests` now (Task 3); `rowLabel` is gone because the table renders columns directly.

- [ ] **Step 5: Build the full target**

Run: `xcodebuild -scheme voxline -destination 'platform=macOS,arch=arm64' build 2>&1 | tail -10`
Expected: `** BUILD SUCCEEDED **`. If you see `Cannot find 'DictationHistoryMenu' in scope`, an import or callsite was missed — search for `DictationHistoryMenu` across `voxline/` and fix.

Run: `grep -rn "DictationHistoryMenu\|DictationHistoryMenuFormatter" voxline voxlineTests`
Expected: no matches.

- [ ] **Step 6: Run the full test suite**

Run: `xcodebuild -scheme voxline -destination 'platform=macOS,arch=arm64' test 2>&1 | tail -10`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 7: Manual smoke (developer only — quick sanity)**

Run the app from Xcode. From the menu bar:
1. Click the Voxline icon → confirm a "Show history…" button appears in place of the "Recent dictations" submenu.
2. Click "Show history…" → the window opens. If history is empty, the empty-state placeholder is centered.
3. Dictate a short phrase into any app → confirm a new row appears with Time/Mode/App/Preview.
4. Click the row → clipboard contains that text and the "Copied" toast fires (whichever surface displays toast in this build).
5. Click "Clear history" → table replaces itself with the empty state.

If anything fails, fix before committing.

- [ ] **Step 8: Commit**

```bash
git add voxline/MenuBar/MenuBarContent.swift voxline/voxlineApp.swift
git commit -m "feat(history): cut menu bar over to history window; remove submenu (#16)"
```

(The two `git rm` operations from Steps 3–4 are already staged, so this single commit picks them up too.)

---

## Task 7: Update smoke matrix doc

**Files:**
- Modify: `docs/insertion-smoke-matrix.md`

Documents the manual cases for the new window, including the backwards-compat decode path.

- [ ] **Step 1: Append the History window section**

Open `docs/insertion-smoke-matrix.md` and add the following section at the end of the file:

```markdown
## Dictation history window (feature #16, 2026-05-11 evolution)

Smoke the standalone history window. Replaces the previous "Recent dictations"
submenu check.

| Case                                        | Expected                                                                                                |
| ------------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| Open via "Show history…"                    | Window titles "Voxline History", 720×480 default, table with Time/Mode/App/Preview columns              |
| Empty history                               | Empty-state placeholder centered; "Clear history" disabled                                              |
| Dictate into Slack                          | Top row shows `Slack` in Mode column, `Slack` in App column                                             |
| Dictate into Mail                           | Row shows `Email` in Mode, `Mail` in App                                                                |
| Dictate into Cursor                         | Row shows `Code` in Mode, `Cursor` in App                                                               |
| Dictate into Safari (unlisted app)          | Row shows `Default` in Mode (wildcard), `Safari` in App                                                 |
| Click any row                               | Clipboard receives `cleanedText`; "Copied" toast fires for ~1.2s                                        |
| Click "Clear history"                       | Table replaced by empty state; no confirmation prompt                                                   |
| Quit + relaunch                             | Existing rows persist                                                                                   |
| Manually pre-seed UserDefaults old-shape JSON under `voxline.history.dictations` (3 fields only) | After relaunch, rows render with `—` in Mode and App columns; no crash |
| Open History twice without closing          | Existing window is brought forward (no second window)                                                   |
```

- [ ] **Step 2: Commit**

```bash
git add docs/insertion-smoke-matrix.md
git commit -m "docs(smoke): add history window cases (#16)"
```

---

## Self-Review Notes

- **Spec coverage:**
  - *Architecture / Components / Data flow* → Tasks 1–6 (each component in its own task).
  - *Data model + decodeIfPresent migration* → Task 1 (test-first).
  - *Capacity bump 10 → 25* → Task 2.
  - *Pipeline call-site update* → Task 2.
  - *Window UX (table, columns, click-to-copy, clear button, empty state)* → Task 4.
  - *Window plumbing (NSWindow + NSHostingController)* → Task 5.
  - *Menu-bar cut-over* → Task 6.
  - *Old menu deletion* → Task 6 (in the same commit so no dead-code window).
  - *Testing unit + integration cases* → Tasks 1, 2, 3 (each test enumerated in the spec is included verbatim).
  - *Manual smoke matrix* → Task 7.
- **Placeholder scan:** No "TBD"/"TODO". Every code step shows the actual code. Every test step shows the actual test. Every shell command is concrete.
- **Type consistency:**
  - `DictationHistoryItem` field names (`modeDisplayName`, `modeBundleID`, `appName`, `appBundleID`) are identical across Tasks 1, 2, 4, 7.
  - `DictationHistoryStore.record(cleanedText:mode:context:)` signature defined in Task 2, consumed in Tasks 2, 6.
  - `HistoryViewFormatter.previewText(_:maxChars:)` defined in Task 3, consumed in Task 4.
  - `HistoryWindowController.show(store:state:)` defined in Task 5, consumed in Task 6.
  - `MenuBarContent.openHistoryWindow` defined in Task 6 Step 1, wired in Task 6 Step 2.
- **Build-green between commits:**
  - Task 1: optional fields added with default-nil init params → old `record(cleanedText:)` still compiles.
  - Task 2: `record` signature widened and pipeline call site updated in the same commit.
  - Task 3: new formatter + placeholder view; unreferenced.
  - Task 4: view body replaces placeholder; still unreferenced.
  - Task 5: window controller; unreferenced.
  - Task 6: menu bar cut-over + old menu deletion in one commit — no intermediate state where the old menu and new button coexist or where the old menu is orphaned.
- **Out-of-band risk note:** If the existing `CapturePipelineTests` happens to use a `Mode` or `CapturedContext` value the engineer didn't seed with deterministic strings, Task 2 Step 6 will surface that — that's the spec's intended behavior, not a plan defect.
