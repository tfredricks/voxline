# Dictation History — Design

**Date:** 2026-05-11
**Feature:** docs/features.md #16 — Dictation history
**Status:** Design approved, ready for implementation plan

## Summary

Add a "Recent dictations" submenu to the menu bar showing the last 10 cleaned-up dictations. Clicking a row copies that text to the clipboard and shows a brief "Copied" toast. Persists across app restarts via `UserDefaults`. Includes a "Clear History" action.

## Goals

- Let users quickly reference and re-use the last 10 things they dictated.
- Zero friction: one click from the menu bar to clipboard.
- Survive app restarts.
- Lay groundwork for feature #15 (privacy controls) without building those controls now.

## Non-Goals (v1)

- Re-pasting directly into the focused app (chose copy + toast for safety/simplicity).
- Configurable history length (fixed at 10).
- "Pause history" toggle (deferred to feature #15).
- Storing raw transcripts, target app, model, or duration.
- A full History view in Settings (menu bar is sufficient for v1).
- Search / filter / re-run cleanup on a history item.

## Architecture

A new `DictationHistoryStore` (MainActor, observable) owns the list and persistence. `CapturePipeline` calls `store.record(cleanedText:)` after a successful cleanup. `MenuBarContent` observes `store.items` and renders the submenu.

```
CapturePipeline (cleanup done, lastCleanedText set)
  → store.record(cleanedText:)
  → UserDefaults write (JSON-encoded)
  → MenuBarContent observes change, re-renders submenu

User clicks a row
  → NSPasteboard.general.clearContents() + setString(item.cleanedText, forType: .string)
  → Toast ("Copied") via RecordingPillWindow for ~1.2s
```

## Components

### `DictationHistoryStore` (new)

`voxline/Storage/DictationHistoryStore.swift`

```swift
@MainActor
final class DictationHistoryStore: ObservableObject {
    @Published private(set) var items: [DictationHistoryItem] = []

    init(defaults: UserDefaults = .standard) { ... }

    func record(cleanedText: String)  // skip if whitespace-only; cap at 10
    func clear()
}
```

- Newest first.
- Cap enforced on write: `items = ([new] + items).prefix(10).map { $0 }`.
- Whitespace-only text is ignored (defensive — pipeline already short-circuits empty transcripts).
- Persists to `UserDefaults` under key `"dictationHistory"`, JSON-encoded `[DictationHistoryItem]`.
- On init, decodes the array; if data is missing or corrupt, starts empty.

### `DictationHistoryItem` (new)

Co-located with the store.

```swift
struct DictationHistoryItem: Codable, Identifiable, Equatable {
    let id: UUID
    let timestamp: Date
    let cleanedText: String
}
```

Cleaned text only — no raw transcript, no target app, no model.

### `CapturePipeline` (modified)

`voxline/Pipeline/CapturePipeline.swift`

Inject a `DictationHistoryStore` reference. After `state.lastCleanedText = cleaned` (around line 175), call:

```swift
historyStore.record(cleanedText: cleaned)
```

### `MenuBarContent` (modified)

`voxline/MenuBar/MenuBarContent.swift`

Add a "Recent dictations" submenu between Pause/Resume and Settings:

```
[error banner, if any]
─────────────
Pause / Resume

Recent dictations ▸
─────────────
Settings…
Debug…
About
Quit
```

Submenu contents:
- If `items.isEmpty`: a single disabled item — "No recent dictations".
- Otherwise: up to 10 rows. Each row label is `"<preview> · <relative-time>"`.
  - Preview: first 50 chars of cleaned text, with newlines/tabs collapsed to single spaces, trimmed, then ellipsized with `…` if truncated.
  - Relative time: `RelativeDateTimeFormatter` (e.g., "just now", "2m ago", "yesterday").
- Separator.
- "Clear History" item. Disabled when `items.isEmpty`. On click → `store.clear()`.

### Toast feedback

Reuse `RecordingPillWindow` to flash "Copied" for ~1.2s after a row click. If the pill doesn't already have a generic-message hook, add a small `showToast(_ message: String, duration: TimeInterval = 1.2)` method. If adding a toast hook proves intrusive, fall back to no toast for v1 — the clipboard change is itself the implicit feedback.

### Composition root

Wherever `AppState` and `CapturePipeline` are constructed today (likely `voxlineApp.swift` or `AppState.swift`), instantiate `DictationHistoryStore()` and inject it into both `CapturePipeline` and `MenuBarContent`.

## Data Flow

**Recording:**
1. User releases hotkey.
2. Pipeline transcribes → cleans → assigns `state.lastCleanedText`.
3. Pipeline calls `historyStore.record(cleanedText:)`.
4. Store prepends, caps at 10, writes JSON to UserDefaults, publishes change.
5. SwiftUI menu rebuilds.

**Recall:**
1. User opens menu bar → hovers "Recent dictations".
2. Submenu renders up to 10 rows from `store.items`.
3. User clicks a row.
4. Handler copies `item.cleanedText` to `NSPasteboard.general`.
5. `RecordingPillWindow.showToast("Copied")` for ~1.2s.

**Clearing:**
1. User clicks "Clear History" in the submenu.
2. `store.clear()` empties `items` and writes empty array to UserDefaults.
3. Submenu shows "No recent dictations".

## Error Handling

- **Corrupt UserDefaults payload:** init catches decode failures, logs at debug level, starts with empty list. Does not crash.
- **UserDefaults write failure:** UserDefaults writes don't throw; nothing to handle.
- **Empty pasteboard target:** `NSPasteboard.general.setString` returning `false` is logged but not surfaced — the toast still shows "Copied" because at this point the failure is exotic enough that bothering the user is worse than a tiny lie. (Revisit if this turns out to fire in practice.)

## Privacy Considerations

- Stored data is **cleaned text only** — no audio, no raw transcript, no target app.
- Persisted in the app's `UserDefaults` container (sandboxed to the app).
- "Clear History" gives one-click wipe.
- Store is designed so a future feature-#15 toggle can wrap `record()` with a no-op without further refactoring.

## Testing

### Unit tests — `voxlineTests/DictationHistoryStoreTests.swift` (new)

Use a per-test `UserDefaults(suiteName: ...)` for isolation (match the existing pattern from `AppSettingsTests.swift`).

- `record_addsNewestFirst` — record A then B → `items == [B, A]`.
- `record_capsAtTen` — record 12 items → 10 retained, oldest dropped.
- `record_skipsWhitespaceOnly` — `"   \n\t  "` → no change.
- `clear_emptiesList` — populated store → `clear()` → `items.isEmpty`.
- `persistence_roundTrip` — record 3 items, build a new store on the same suite → reads back same 3 items in order.
- `persistence_handlesCorruptData` — pre-seed the suite with non-decodable bytes under the key → new store init returns empty list, no crash.

### Pipeline integration test — extend `CapturePipelineTests`

- Inject a real `DictationHistoryStore` (on an isolated `UserDefaults` suite) into the pipeline under test. After a successful cleanup run, assert `store.items.count == 1` and `store.items[0].cleanedText` equals the expected text. (No mocking — the store is small enough and side-effect-free enough that asserting on its real state is simpler than introducing a protocol.)

### Manual smoke

- Dictate three short phrases → open menu bar → confirm submenu shows all three newest-first with sensible relative timestamps.
- Click middle row → pasteboard contains that text, "Copied" toast appears.
- Quit and relaunch → submenu still shows the three items.
- "Clear History" → submenu shows "No recent dictations" → relaunch → still empty.

## Out of Scope / Future Work

- Pause-capture toggle and audio-retention controls (feature #15).
- Search, tagging, or longer history with a Settings view (could come if users ask).
- Re-run cleanup with a different prompt (needs raw transcript, which we don't store).
- Sync across devices (not on the roadmap).
