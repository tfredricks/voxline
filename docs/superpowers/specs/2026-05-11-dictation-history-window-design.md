# Dictation History Window — Design

**Date:** 2026-05-11
**Feature:** evolves [docs/features.md #16 — Dictation history](../../features.md)
**Predecessor:** [2026-05-11-dictation-history-design.md](2026-05-11-dictation-history-design.md)
**Status:** Design approved, ready for implementation plan

## Summary

Replace the menu-bar "Recent dictations" submenu with a standalone window. The window shows up to 25 recent cleaned dictations in a table with **Time · Mode · App · Preview** columns, lets the user click any row to copy that text, and exposes a Clear-history button. Each entry now records which mode produced it and which app was frontmost at capture time. Existing on-disk history rows decode cleanly without those fields.

## Goals

- Surface the resolved mode for every dictation so the user can scan history by context.
- Provide a real window for browsing instead of a tall popup menu — the existing submenu had no room for per-row metadata.
- Keep the one-click copy-to-clipboard interaction unchanged.
- Bump capacity from 10 to 25 (still small enough to stay in `UserDefaults`).

## Non-Goals (v1)

- Search, filter, sort, multi-select, per-row delete.
- Storing or showing raw transcript, window title, or paste outcome.
- Re-paste-into-frontmost-app.
- Configurable retention or per-mode capacity.
- Window-size persistence between launches.

## Architecture

A new `HistoryWindowController` follows the existing `DebugWindowController` and `AboutWindowController` pattern: a lazy `NSWindow` hosting a SwiftUI `HistoryView`. The menu-bar entry changes from `DictationHistoryMenu` (a SwiftUI `Menu`) to a plain `Button("Show history…")` that calls `historyWindow.show(...)`.

```
MenuBarContent
  Button("Show history…") → historyWindow.show(store:state:)
                                 │
                                 ▼
                         HistoryWindowController (NSWindow + NSHostingController)
                                 │
                                 ▼
                         HistoryView (SwiftUI Table over store.items)
                            │           │
                            │ click row │ click Clear
                            ▼           ▼
                NSPasteboard       store.clear()
                state.toastMessage = "Copied"
```

The recording side adds two arguments to the existing call site in `CapturePipeline`:

```
mode + context (already in scope at line 194)
        │
        ▼
historyStore.record(cleanedText:mode:context:)
        │
        ▼
DictationHistoryItem(modeDisplayName:..., modeBundleID:..., appName:..., appBundleID:...)
        │
        ▼
UserDefaults write (JSON-encoded array)
        │
        ▼
HistoryView observes change, table re-renders
```

`DictationHistoryStore` keeps its existing `@Observable @MainActor` shape and `UserDefaults`-backed persistence. The store's contract widens (`record` takes mode + context) but its responsibilities don't.

## Components

### `DictationHistoryItem` (modified)

`voxline/Storage/DictationHistoryStore.swift`

Adds four optional fields. All decode through `decodeIfPresent` so old rows on disk load with nil for the new columns.

```swift
struct DictationHistoryItem: Codable, Identifiable, Equatable {
    let id: UUID
    let timestamp: Date
    let cleanedText: String
    let modeDisplayName: String?   // e.g. "Slack" — the resolved Mode.displayName
    let modeBundleID: String?      // e.g. "com.tinyspeck.slackmacgap" or "*"
    let appName: String?           // CapturedContext.appName (frontmost localized name)
    let appBundleID: String?       // CapturedContext.bundleID
}
```

### `DictationHistoryStore` (modified)

Same file. Two surface changes:

```swift
private static let maxItems = 25   // was 10

func record(cleanedText: String, mode: Mode, context: CapturedContext)
```

`record` extracts the new fields from `mode` and `context` and constructs the item. Whitespace-only `cleanedText` is still ignored. The cap-on-write logic is unchanged.

### `HistoryView` (new)

`voxline/UI/HistoryView.swift`

```swift
struct HistoryView: View {
    @Bindable var store: DictationHistoryStore
    @Bindable var state: AppState
    var body: some View { ... }
}
```

- `Table(store.items)` with four columns (`KeyPath`-typed where natural):
  - **Time** — `RelativeDateTimeFormatter` (`.short` units), e.g. "just now", "2m ago", "yesterday".
  - **Mode** — `item.modeDisplayName ?? "—"`.
  - **App** — `item.appName ?? item.appBundleID ?? "—"`.
  - **Preview** — `previewText(item.cleanedText, maxChars: 80)` (whitespace collapsed, ellipsized).
- Row tap copies `cleanedText` and sets `state.toastMessage = "Copied"` for 1.2s (matches existing menu behavior). Use `.contentShape(Rectangle()).onTapGesture` on the row to fire on a single click without introducing a selection-state binding — the row is an action, not a selectable item.
- Row tooltip (`.help`): full ISO-ish timestamp + full cleaned text.
- Toolbar (`.toolbar`): `Button("Clear history") { store.clear() }`, disabled when empty.
- Empty state: when `store.items.isEmpty`, render a centered `Text("No recent dictations.")` instead of the table.

A formatting helper `previewText(_:maxChars:)` is reused from the existing `DictationHistoryMenuFormatter`. The deleted file's `rowLabel` is not reused — the table renders columns directly.

### `HistoryWindowController` (new)

`voxline/UI/HistoryWindowController.swift`

```swift
@MainActor
final class HistoryWindowController {
    private var window: NSWindow?
    func show(store: DictationHistoryStore, state: AppState)
}
```

- Lazy creation: `show()` brings the existing window to front via `makeKeyAndOrderFront` if one exists; otherwise constructs `NSWindow(styleMask: [.titled, .closable, .resizable, .miniaturizable])`, embeds `NSHostingController(rootView: HistoryView(store: ..., state: ...))`, sets title "Voxline History", default size 720 × 480, calls `center()`, sets `isReleasedWhenClosed = false`, assigns `WindowVisibilityCoordinator.dockworthyIdentifier`, then `makeKeyAndOrderFront` + `NSApp.activate()`.
- No state persisted between launches.

### `MenuBarContent` (modified)

`voxline/MenuBar/MenuBarContent.swift`

Replace the `DictationHistoryMenu(store: historyStore, state: state)` line with:

```swift
Button("Show history…") { openHistoryWindow() }
```

Add `var openHistoryWindow: () -> Void = {}` to the struct alongside the existing `openDebugWindow` / `openAboutWindow` properties.

### `DictationHistoryMenu` (deleted)

`voxline/MenuBar/DictationHistoryMenu.swift` is removed. The `DictationHistoryMenuFormatter.previewText` helper migrates to `HistoryView.swift` as a private helper (or co-located free function) so its existing tests still target the same logic by import path. `DictationHistoryMenuFormatter.rowLabel` is deleted along with its tests.

### `voxlineApp.swift` (modified)

Add `let historyWindow = HistoryWindowController()` alongside the existing `debugWindow`. Wire it into `MenuBarContent`:

```swift
MenuBarContent(
    state: appState,
    historyStore: delegate.historyStore,
    openDebugWindow: { delegate.debugWindow.show(...) },
    openAboutWindow: { delegate.aboutWindow.show(...) },
    openHistoryWindow: { delegate.historyWindow.show(store: delegate.historyStore, state: appState) },
    tagSettingsWindow: ...
)
```

### `CapturePipeline` (modified)

`voxline/Pipeline/CapturePipeline.swift:194`

```swift
// before
historyStore.record(cleanedText: cleaned)
// after
historyStore.record(cleanedText: cleaned, mode: mode, context: context)
```

Both `mode` (resolved at line 163) and `context` are already in scope.

## Data Flow

**Recording (one new field-extraction step):**
1. Pipeline resolves `mode` and awaits `context`.
2. LLM cleanup succeeds; `state.lastCleanedText = cleaned`.
3. `historyStore.record(cleanedText: cleaned, mode: mode, context: context)`.
4. Store builds a `DictationHistoryItem` with all four new fields populated.
5. Store prepends, caps at 25, writes JSON to `UserDefaults`, publishes change.

**Recall (window):**
1. User picks "Show history…" from the menu bar.
2. `HistoryWindowController.show()` creates or surfaces the window.
3. `HistoryView` renders the table from `store.items`.
4. User clicks a row → `NSPasteboard.general` populated with `item.cleanedText`, toast "Copied" for 1.2s.

**Clearing:**
1. User clicks "Clear history" in the window toolbar.
2. `store.clear()` empties `items` and persists empty array.
3. Table replaces itself with the empty-state label.

## Migration / Backwards-Compatibility

- The on-disk JSON for existing entries omits `modeDisplayName`, `modeBundleID`, `appName`, `appBundleID`. `Codable`'s default synthesis combined with optional types performs an implicit `decodeIfPresent` — old rows load with nil for the new fields.
- No version field is introduced. If a later change is genuinely breaking, that's when versioning gets added.
- Capacity bump (10 → 25) is one-directional. Existing users see at most 10 historical rows until they dictate more.
- `DictationHistoryMenuFormatter.rowLabel` and its tests are removed in this change because no menu-style label is rendered anywhere after the switch. `previewText` survives as the column renderer for the Preview column.

## Error Handling

- Corrupt `UserDefaults` payload: existing behavior preserved — decode failure starts an empty list. Logged at debug level.
- `CapturedContext.empty` (AX denied or capture failed entirely): the row stores nil app fields; the App column renders "—". No error path.
- Wildcard mode (`*`): `modeDisplayName == "Default"`, `modeBundleID == "*"`. Both columns render the literal strings — no special-casing.
- Window already open: `show()` calls `makeKeyAndOrderFront`, matching `DebugWindowController`.
- Empty pasteboard target on row click: `NSPasteboard.general.setString` returning false is logged at debug level but not surfaced. Toast still says "Copied". (Same posture as the original menu implementation.)

## Privacy Considerations

- New fields are app/mode metadata, not content. They reveal *where* the user was dictating, not additional dictation text.
- Window title was deliberately excluded — that field can leak document/channel/recipient identity (e.g., `Re: salary discussion`) in a way bundle ID does not.
- "Clear history" still wipes the entire list in one click.
- Storage location is unchanged: app-sandboxed `UserDefaults`.

## Testing

### Unit — `voxlineTests/DictationHistoryStoreTests.swift` (extend)

Existing tests targeting the 10-cap and the old `record(cleanedText:)` signature need updates. New + updated cases:

- `record_capturesMode` — record with `Mode(bundleID: "com.test", displayName: "Test", prompt: "p", model: nil, temperature: nil)` → assert `items.first?.modeDisplayName == "Test"` and `modeBundleID == "com.test"`.
- `record_capturesApp` — record with a `CapturedContext` whose `appName = "Slack"` and `bundleID = "com.tinyspeck.slackmacgap"` → assert both fields on the stored item.
- `record_emptyContext_storesNilAppFields` — record with `CapturedContext.empty` → `appName` and `appBundleID` are nil on the stored item.
- `record_wildcardMode_storedVerbatim` — record with the wildcard Mode (`bundleID == "*"`, `displayName == "Default"`) → fields stored as-is.
- `cap_lifted_to_25` — record 30 items → 25 retained, oldest dropped. Replaces the existing 10-cap test.
- `loadsOldSchemaJSON_nilNewFields` — pre-seed the test `UserDefaults` suite with hand-crafted JSON in the old 3-field shape → new store loads, item count matches, all new fields are nil.
- `record_skipsWhitespaceOnly` — unchanged behavior, but signature now passes a Mode + context.
- `clear_emptiesList` — unchanged.
- `persistence_roundTrip` — extended to assert the new fields survive a write/read cycle.

### Integration — `voxlineTests/CapturePipelineTests.swift` (extend)

The existing assertion (`store.items.count == 1` after a successful cleanup) is extended to also assert `modeDisplayName`, `modeBundleID`, `appName`, and `appBundleID` match the values that were injected via the test's fake `ModeResolving` and fake `ContextCapturing`.

### View tests

None. SwiftUI views are not unit-tested in this project. The unit + integration coverage exercises the data plumbing; manual smoke covers UX.

### Manual smoke — extend `docs/insertion-smoke-matrix.md`

A new "History window" sub-section:

- Dictate into Slack, Mail, Cursor, Safari (no shipped mode) in any order.
- Open History via the menu bar.
- Confirm rows show: resolved mode (`Slack`, `Email`, `Code`, `Default`) and app name for each.
- Click the middle row → clipboard contains its `cleanedText`, "Copied" toast fires.
- Click "Clear history" → table replaced by empty-state label.
- Quit + relaunch → empty table persists.
- Manually pre-seed `UserDefaults` under `voxline.history.dictations` with a 3-field JSON array (the pre-change shape) → relaunch → rows render with "—" in Mode and App columns.

## Out of Scope / Future Work

- Search / filter / sort interactions.
- Per-row delete and multi-select.
- Window-size persistence across launches.
- Storing raw transcript so we can re-run cleanup with a different mode.
- Window-title storage (deliberately deferred for privacy reasons).
- Switching the storage backend to a file under `AppPaths` — only worth doing if retention grows past a few hundred entries.
