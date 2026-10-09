# Settings pages: split Settings into sidebar pages

**Date:** 2026-10-09
**Status:** Approved design; not yet planned.
**Builds on:** `2026-10-09-main-window-design.md` (the main window and its sidebar).

## Goal

Settings is one long page of 13 sections. It is hard to scan, and it has
layout and scroll bugs. Split it into six short pages in the main window's
sidebar, as System Settings, Wispr Flow and Raycast do. Fix the layout bugs
along the way.

## Problems today

Found in the code and in a screenshot of build 676:

1. **Capped width.** `SettingsView` sets `.frame(maxWidth: 520)`. In the
   detail column, which is about 700 pt or wider, that leaves empty bands
   left and right. The status strip, the form and its scroll bar all stop at
   520 pt, so the scroll bar floats mid-window.
2. **The title sits over the left band.** The Settings page sets no
   `navigationTitle`, so the toolbar shows "Voxline" over the empty band with
   a blank strip above the status strip.
3. **Nested scrolling.** Each Learning style note is a `TextEditor` inside
   the scrolling `Form`. With the pointer over one, the scroll wheel scrolls
   the note, not the page.
4. **Loose fragments.** `APIKeyRow` wraps itself in its own `Section(title)`,
   so the key appears as a separate "Anthropic" or "OpenAI" section, apart
   from "Cleanup (AI)". "Reset to Defaults" is an `HStack` placed directly in
   the `Form` with no section.
5. **Unreliable jump links.** The status strip jumps to sections with
   `ScrollViewReader.scrollTo` on `Form` sections, which is unreliable. The
   strip also repeats what Home shows.
6. **No order, and a duplicated label.** Startup and Updates come before
   Hotkey. The command settings are split between the Hotkey and Command
   sections. Two rows are both labelled "Command mode" (the switch and its
   hotkey).
7. **Monospaced hotkey names.** "Left Shift + Left Ctrl" reads like code.

## Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Structure | Settings pages in the main window's sidebar, under a "Settings" header | Matches System Settings and competitors. It reuses the split view and keeps each page short. |
| Pages | General, Dictation, AI Provider, Commands, Vocabulary, Meetings | Grouped by task. Learning goes with Vocabulary because learned words land in that list. |
| Status strip | Removed | Home shows readiness, and the sidebar flags pages that need setup. |
| Settings… (⌘,) | Opens General | Predictable. No last-page memory (YAGNI). |
| View model lifetime | One `SettingsModel` per window build, shared by every page | Switching pages must not lose state or reset view models. |
| Width | Pages fill the detail column, as Home does | Fixes problems 1 and 2. |

## Sidebar

```
Home
SETTINGS
  General
  Dictation      ⚠︎ (when it needs setup)
  AI Provider    ⚠︎ (when it needs setup)
  Commands
  Vocabulary
  Meetings
```

- `MainWindowPage` becomes
  `.home, .general, .dictation, .aiProvider, .commands, .vocabulary, .meetings`.
  `.settings` is removed. Settings… in the app menu and the menu-bar menu
  opens `.general`.
- `MainWindowPage.settingsPages` lists the six pages in order. Each page has a
  `title` and a `systemImage`. Symbols: General `gearshape`, Dictation `mic`,
  AI Provider `sparkles`, Commands `command`, Vocabulary `character.book.closed`,
  Meetings `person.2`.
- A page that needs setup shows `exclamationmark.circle.fill` in orange at
  the trailing edge of its row, with the issue text as help.
- The sidebar keeps its width (160–220, ideal 180). The window minimum stays
  720×480.

## Pages

Every page is a `Form` with `.formStyle(.grouped)` and `.navigationTitle(page.title)`.
There is no `.scrollContentBackground(.hidden)` and no frame cap, so pages
match Home. A shared `SettingsPage` wrapper applies this.

### General
- **Startup:** Launch Voxline at login, with the existing approval link when
  needed; Show Voxline in Dock, with its footnote.
- **Updates:** Automatically check for updates. Footnote: "Voxline checks once
  a day and shows a badge on the menu-bar icon when an update is ready."
- **Sounds:** Play sound on record start/stop.
- An untitled last section with **Reset to Defaults…**, which asks first:
  - Dialog title: "Reset settings to defaults?"
  - Message: "Hotkeys, microphone, recognition, AI provider, command model
    and sounds go back to their defaults. API keys, presets, vocabulary,
    learning and meeting settings stay."
  - Destructive button: "Reset". It calls `generalVM.resetToDefaults()`,
    which is unchanged.

### Dictation
- **Hotkey:** the Dictation chord recorder. Footnote: "Hold to dictate;
  release to insert the cleaned-up text."
- **Microphone:** Input device picker and Live level meter.
- **Recognition:** Engine picker, then the engine's extras, all in the same
  section:
  - **Whisper:** the model picker and its note.
  - **OpenAI Realtime:** the note and the key warning, plus the OpenAI key
    rows when `showsOpenAIKeyInRecognition`.
  - **Apple:** nothing extra.
- The mic level monitor lives on this page only. It starts on appear, stops
  on disappear, and stops while recording. That is today's logic, moved here
  from `SettingsView`.

### AI Provider
- **Provider:** the segmented Anthropic/OpenAI picker. Footnote: "Cleans up
  dictation, runs commands and writes meeting notes."
- **"<Provider> API key"** section: the rows of `APIKeyRow` for the selected
  provider. These are the key field, reveal, Save or Saved, the prefix
  warning, the "Get a key" link, Test with its result, and the error.
  - Switching provider resets "revealed", as today.
  - The row is rebuilt per provider with `.id(provider)`, as today.

### Commands
- **Command mode:** a switch labelled "Command mode". When on, a "Hotkey" chord
  recorder appears below it. Then the footnote "Hold to speak an edit: rewrite
  the selection, draft a reply, or change part of the field." Then the
  "Model" text field, with the cleanup model as placeholder and its existing
  note.
- **Presets:** the preset rows, "Add preset", "Restore default presets", and
  the existing ⌥-key note. Presets show whether or not command mode is on,
  because they run independently of the command chord.

### Vocabulary
- **Custom vocabulary:** unchanged from `CustomVocabularyListView`.
- **Learning:** the two switches and their notes, the per-category style
  notes, Regenerate, and Reset Learning….
  - Each note becomes `TextField(axis: .vertical)` with `.lineLimit(3...10)`
    and the rounded-border style, instead of `TextEditor`. It grows with its
    text and never scrolls inside the page (fixes problem 3).
  - Drafts still commit on disappear, through `commitAllDrafts()`.

### Meetings
The same controls as today, in two sections:
- **Recording:** Start/stop shortcut, Show recording timer, Keep meeting
  audio, and the existing privacy and headphones note.
- **Notes:** Notes folder and Meeting notes model.

## Home: setup issues

Home gains a **Setup** section above Permissions, shown only when there are
issues. Each issue is one row with its text and a button that selects the
page. Issues:

| Issue | Text | Page |
|---|---|---|
| Saved mic missing, or no input devices | "Microphone not found" | Dictation |
| Engine `.unavailable(reason)` | the reason | Dictation |
| Engine `.needsPreparation(mb)` | "<engine> needs a one-time download (N MB)", or without the size when nil | Dictation |
| Selected provider's key not saved | "No <provider> API key" | AI Provider |

An engine readiness that hasn't been checked yet (nil, including "engines not
built yet") is **not** an issue. This differs from today's strip, which
showed "Setup needed" until the check finished. The difference avoids a
flash of orange at every window open. The same issues drive the sidebar
marks.

## Architecture

- **`SettingsModel`** (new, `voxline/Settings/SettingsModel.swift`,
  `@Observable @MainActor`):
  - It owns `general`, `apiKeys`, `command`, `meetings`, `vocabulary`,
    `learning` (the `LearningSettingsViewModel`) and `status`.
  - The window's content closure in `AppDelegate` builds it once per window
    build, replacing `makeSettingsView()`. It is released with the window
    content on close, as the content is today.
  - `refresh()` runs `refreshFromUserDefaults()` and
    `refreshLoginItemStatus()`. It is called from a `.task` on
    `MainWindowView`. The engine readiness check runs from
    `MainWindowView`'s `.task(id: status.readinessKey)`, so `refresh()`
    doesn't repeat it.
- **`SettingsStatusViewModel`** keeps its readiness logic and gains:
  - `issues: [SetupIssue]`;
  - `needsSetup(_ page: MainWindowPage) -> Bool`.

  The chip properties (`micChipText`, `engineChipText`,
  `engineChipShowsCheck`, `providerChipText`, `providerChipShowsCheck`)
  and `isReady` are removed with the strip. `SetupIssue` is a value type
  with `text` and `page`.
- **`MainWindowView`** takes the selection, a `HomeView` and the
  `SettingsModel`. It builds the sidebar from `settingsPages` and switches the
  detail on the page. It also hosts:
  - the readiness `.task(id: status.readinessKey)`;
  - the `.onChange(of: appState.status)` re-check when recording unblocks;
  - the `.onChange(of: learning.vocabularyRevision)` vocabulary reload.

  These must keep running whichever page is shown.
- **Page views** live in `voxline/Settings/Pages/`:
  - `SettingsPage.swift` (the wrapper);
  - `GeneralSettingsPage`, `DictationSettingsPage`, `AIProviderSettingsPage`,
    `CommandsSettingsPage`, `VocabularySettingsPage`, `MeetingsSettingsPage`.
  - Existing components are reused where they fit: `CustomVocabularyListView`,
    `LearningSection`, `ChordRecorderView`, `KeyComboRecorderView`,
    `APIKeyRow`, `OpenAIKeyRow`, `MicLevelMeter`.
  - `CleanupSection`, `CommandSection` and `MeetingsSection` are replaced by
    their pages. The preset row and `CommittingTextField` move with the
    Commands page.
- **Deleted:** `SettingsView.swift`, `SettingsStatusStrip.swift` (with
  `SettingsAnchor`), `CleanupSection.swift`, `CommandSection.swift` and
  `MeetingsSection.swift`.
- **`APIKeyRow`** emits rows, not a `Section`, so the caller places it.
  It also commits on disappear, so leaving the page mid-edit saves the key the
  same way losing focus does.
- **Recorders:** `.monospaced()` is dropped from `ChordRecorderView` and
  `KeyComboRecorderView`.
- **`HomeView`** takes `issues: [SetupIssue]` and an
  `open: (MainWindowPage) -> Void`, so it doesn't depend on the settings
  view models.

## Testing

- **`SettingsStatusViewModelTests`:** rewrite the strip and `isReady` tests as
  issue tests: each issue appears and clears; unchecked readiness gives no
  issue; `needsSetup` maps issues to pages. The readiness-key and
  superseded-check tests stay.
- **`MainWindowPage`:** `settingsPages` order, titles and symbols are fixed.
- **`MainWindowControllerTests`:** `show(.general)` selects General (replaces
  the `.settings` case).
- **`SettingsModel`:** `refresh()` reloads defaults into `general`. Vocabulary
  removal and addition reach the `LearningCoordinator`, as today.
- **Manual (`MANUAL_TESTS.md`):** for each page, check fit at 720×480 and at
  full screen. Also check:
  - no nested scrolling on Vocabulary;
  - the mic indicator is off on every page but Dictation;
  - a key typed and left by switching pages is saved;
  - ⌘, opens General;
  - sidebar marks and Home's Setup rows appear and clear.

## Out of scope

- New settings (for example, a cleanup-model field or per-app modes UI).
- Search in Settings.
- Remembering the last settings page.
