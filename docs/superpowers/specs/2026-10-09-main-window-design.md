# Main window: Home and Settings, and the Dock icon (fixes #29)

**Date:** 2026-10-09
**Status:** Approved design. Implementation waits until phase 5 (learning) is on
`main`, because both change `SettingsView`, `voxlineApp.swift` and
`AppCoordinator`.
**Issue:** #29 in `docs/issues.md`, where the Dock icon gets stuck with no window behind it.

## Goal

Give voxline one primary window, as Wispr Flow, Superwhisper and VoiceInk
have, that tucks out of the way when closed. Fix #29 by working out the Dock
icon from the windows actually on screen, and make a Dock click bring the
window back.

## What competitors do (research, October 2026)

- **One window, sidebar, Settings inside it.** Wispr Flow (the "Hub"),
  Superwhisper, VoiceInk and Spokenly all put Settings in the main window.
  The first page is Home or Dashboard.
- **Closing the window never quits.** The app keeps running from the
  menu-bar icon, which is always present. ⌘Q quits.
- **The Dock icon is a user setting.** Wispr Flow has "Show app in dock",
  reportedly off by default. Superwhisper has "Show in Dock", on by default.
  With it off, Wispr Flow and VoiceInk still show the Dock icon while a window
  is visible and drop it when none are.
- **Getting the window back:** a Dock click (`applicationShouldHandleReopen`)
  or "Open …" at the top of the menu-bar menu.
- One open-source clone reported windows not opening over full-screen apps
  after switching to `.regular`. That wasn't confirmed, but it's in the manual
  checks.

Sources: Wispr Flow help center (navigating the app, quit and relaunch, Flow
Bar); superwhisper.com docs and changelog; VoiceInk source
(`github.com/Beingpax/VoiceInk`: `WindowManager.swift`, `AppDelegate.swift`);
EnviousWispr issue #2480, which is secondhand and the only source for Wispr's
default.

## Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Sidebar pages | Home and Settings | History, Dictionary and Meetings stay where they are for now. The sidebar leaves room to add them later. |
| Settings window | Removed. Settings becomes a sidebar page, and ⌘, opens it | Matches every competitor that has a main window. One primary window to manage. |
| Permissions window | Removed. Home shows the permissions | One place to see and fix permissions. |
| Dock icon | "Show Voxline in Dock" setting, off by default | Off: Dock icon only while a window is visible. On: always in the Dock. |
| Dock state source | Recomputed from `NSApp.windows` on every relevant event; no tracked set | A tracked set leaks windows that are ordered out instead of closed (alerts, `NSOpenPanel`). That leak is #29. |
| Window technology | AppKit `NSWindowController` hosting a SwiftUI `NavigationSplitView` | Same pattern as History, About and the wizard. Callable from `AppDelegate` (reopen), the menu bar and the coordinator without bridging SwiftUI's `openWindow`. |
| When the window opens by itself | On a manual launch, after the wizard, and when a required permission is missing. Never on a login launch | Login stays quiet in the menu bar, as Wispr and Willow do. |
| Menu bar | Add "Open Voxline" at the top; drop "Check Permissions…" | Home covers permissions. "Fix permissions…" stays in the error state. |

## Architecture

### `MainWindowController` (new, `voxline/UI/`)

- Owned by `AppDelegate`. Creates its `NSWindow` on first `show`. Style is
  titled, closable, miniaturizable and resizable, with `isReleasedWhenClosed = false`.
  The frame is autosaved, and a minimum size fits the Settings form.
- `show(_ page: MainWindowPage)` selects the page, then calls
  `presentInAccessoryApp()`. `MainWindowPage` is `.home` or `.settings`.
- Content is a `NavigationSplitView`. The sidebar lists Home and Settings, and
  the detail shows `HomeView` or `SettingsView`. The selection is a property
  `show` can set.
- Builds `SettingsView` with the same view models and closures the `Settings`
  scene in `voxlineApp.swift` builds today, including whatever phase 5 adds.
  The construction moves; the arguments don't change.
- Closing hides the window. The app keeps running, and
  `applicationShouldTerminateAfterLastWindowClosed` stays false (the default).
- `AppCoordinator` gets a `presentMainWindow: (MainWindowPage) -> Void`
  closure from `AppDelegate`. It calls this wherever it calls
  `permissionsWindow.show()` today.

### Settings entry points

- The `Settings { … }` scene is removed from `voxlineApp`.
- `.commands { CommandGroup(replacing: .appSettings) { … } }` on the
  `MenuBarExtra` scene adds "Settings…" (⌘,) to the app menu, which opens
  `.settings`.
- The menu-bar "Settings…" item calls the same thing instead of
  `openSettings()`.

### `ActivationPolicyController` (replaces `WindowVisibilityCoordinator`)

A pure rule plus a thin AppKit wrapper.

```swift
struct WindowSnapshot: Equatable {
    var isTitled: Bool
    var isPanel: Bool
    var level: NSWindow.Level
    var isVisible: Bool
    var isMiniaturized: Bool
}

enum DockPolicy {
    static func policy(showInDock: Bool, windows: [WindowSnapshot]) -> NSApplication.ActivationPolicy
}
```

- `showInDock == true` returns `.regular`.
- Otherwise it returns `.regular` if any window is titled, not a panel, at
  `.normal` level, and visible or miniaturized. Anything else returns `.accessory`.
- Panels are excluded: `NSAlert`, `NSOpenPanel`, the recording pill and the
  meeting timer chip. Alerts still come forward in an accessory app through
  `NSApp.activate`. Today's tracking is what pulls them into the Dock state.
- A minimized main window counts as visible, so its Dock tile doesn't vanish.

The controller observes `didBecomeKey`, `willClose`, `didMiniaturize`,
`didDeminiaturize` and `didChangeOcclusionState` (any window), plus changes to
the setting. On each event it works out the policy and calls
`NSApp.setActivationPolicy` only if the result differs from
`NSApp.activationPolicy()`.

- Comparing against the live policy keeps the existing rule that only changes
  are applied: no repeated `.regular` calls interrupting an activation
  (the window flicker `WindowVisibilityCoordinator`'s comments describe),
  with no stored count.
- `willClose` work is deferred one runloop tick, because the closing window is
  still visible inside the notification. This matches today's deferral, and
  VoiceInk does the same.
- On a change to `.regular` caused by a window becoming key, it also calls
  `NSApp.activate()`, as today.

### Dock click and relaunch

`AppDelegate.applicationShouldHandleReopen(_:hasVisibleWindows:)` calls
`mainWindow.show(.home)` and returns false. Opening voxline from
Finder or Spotlight while it's running arrives here too.

### Launch presentation

```swift
enum LaunchPresentation: Equatable { case wizard, home, none }

static func decide(firstRunComplete: Bool, requiredPermissionsGranted: Bool, launchedAtLogin: Bool) -> LaunchPresentation
```

| First run complete | Required perms granted | At login | Result |
|---|---|---|---|
| no | — | — | `.wizard` (main window opens on Home when the wizard finishes) |
| yes | no | — | `.home` |
| yes | yes | yes | `.none` |
| yes | yes | no | `.home` |

The runtime-revocation path (granted → missing in
`reconcileTapWithPermissionsAndEnabled`) calls `presentMainWindow(.home)` in
place of `permissionsWindow.show()`, with the same gating on the previous tick.
`startMeetingRecording`'s microphone guard does the same.

### Gate: detecting a login launch (first task of the plan)

voxline registers with `SMAppService.mainApp`. It isn't certain that macOS still
tags such launches with `keyAELaunchedAsLogInItem` on the open-application
Apple event. Before anything else, a throwaway probe logs that event's
`keyAEPropData` on a real login and on a Finder launch.

- **If it tells the two apart:** use it, read in
  `applicationWillFinishLaunching`.
- **If not, fallback:** count the launch as "at login" when the process
  started within 60 s of the console user's session start, read from the
  `USER_PROCESS` login record (`getutxent`).
- **If neither is reliable:** stop and ask Todd. The likely alternative is an
  "Open window when Voxline starts" setting.

Results are appended to this spec.

## Home page

`HomeView` is backed by a `HomeViewModel`, which reads `AppState`, permissions and
the meeting store. Top to bottom:

1. **Status.** One line with an icon, from the same states as the menu-bar
   icon: Ready, Paused, Recording, Processing, Downloading model (with percent),
   or the current error message. Next to it is a Pause/Resume button bound to
   `state.hotkeyEnabled`. While `updateService.hasPendingUpdate` is true, an
   "Update available — Install" link calls `checkForUpdates()`.
2. **Permissions.**
   - Rows for Accessibility (required), Microphone (required) and Input
     Monitoring (recommended), each with a status and a Grant or Open System
     Settings button.
   - The rows move out of `PermissionsStatusView` into a shared
     `PermissionRows` view. `PermissionsStatusView` and
     `PermissionsWindowController` are deleted.
   - When every required permission is granted, the section collapses to one
     line, "All required permissions granted", with a disclosure to show the
     rows.
   - Status refreshes when the window becomes key and every 1 s while Home is
     on screen.
3. **Recent meetings.** Hidden when `state.meetings` is nil.
   - Shows the last 5 meetings from `MeetingStore.all()`, newest
     `startedAt` first. Each row shows the title (or `MeetingMarkdown.untitled`),
     date and time, and duration.
   - Clicking a row opens `notesPath` with `NSWorkspace`. If there's no
     `notesPath` or the file is gone, the row isn't clickable and reads
     "Notes not available".
   - A meeting in processing shows its stage label. The one matching
     `lastFailedMeeting` shows Retry (`retryFailed()`), disabled unless the
     phase is idle.
   - With no meetings, it shows "No meetings yet" plus the meeting shortcut,
     if one is set.
   - An "Open meetings folder" button opens `meetingNotesFolder` in Finder.
   - The list reloads when the window becomes key and whenever the meeting
     phase changes.

## Menu-bar menu

- New first item: **Open Voxline** (`O` shortcut inside the menu), which opens
  `.home`.
- "Settings…" opens `.settings`.
- "Fix permissions…" (error state) opens `.home`.
- "Check Permissions…" is removed.
- Everything else is unchanged.

## Settings

`SettingsView` is unchanged apart from one toggle in the Startup section:

- **Show Voxline in Dock.** `AppSettings.showInDock`, key
  `voxline.showInDock`, default `false`. Changes take effect immediately
  through `ActivationPolicyController`.

## Files

| File | Change |
|---|---|
| `voxline/UI/MainWindowController.swift`, `MainWindowView.swift`, `HomeView.swift`, `HomeViewModel.swift` | New |
| `voxline/MenuBar/ActivationPolicyController.swift`, `DockPolicy.swift` | New; replace `WindowVisibilityCoordinator.swift` |
| `voxline/LaunchPresentation.swift` (next to `AppCoordinator.swift`) | New |
| `voxline/Permissions/PermissionRows.swift` | New, extracted from `PermissionsStatusView.swift` |
| `voxline/Permissions/PermissionsStatusView.swift`, `PermissionsWindowController.swift`, `voxline/MenuBar/WindowVisibilityCoordinator.swift` | Deleted |
| `voxline/voxlineApp.swift` | Remove `Settings` scene; add `.commands`; `AppDelegate` owns `MainWindowController` and `ActivationPolicyController`; add reopen; login-launch detection |
| `voxline/AppCoordinator.swift` | `presentMainWindow` closure in place of `permissionsWindow`; launch presentation |
| `voxline/MenuBar/MenuBarContent.swift` | Open Voxline; Settings routing; drop Check Permissions |
| `voxline/Settings/SettingsView.swift`, `GeneralSettingsViewModel.swift`, `voxline/Storage/AppSettings.swift` | Show in Dock toggle and setting |
| `voxline/Meetings/MeetingTimerPanel.swift` | Doc comment: refer to `ActivationPolicyController` |

## Testing

Unit tests (Swift Testing):

- `DockPolicyTests`:
  - setting on, with no windows → `.regular`
  - setting off, with no windows → `.accessory`
  - visible titled window → `.regular`
  - minimized window → `.regular`
  - ordered-out titled window (the #29 alert case) → `.accessory`
  - visible panel only (alert, pill, timer chip) → `.accessory`
  - titled window at a non-normal level → `.accessory`
- `LaunchPresentationTests`: every row of the table.
- `HomeViewModelTests` against a temporary `MeetingStore` root:
  - newest first, limited to 5
  - processing stage shown
  - Retry only on the last failed meeting
  - missing notes file → not openable
  - section hidden without meetings
- `AppSettingsTests`: `showInDock` defaults to false and round-trips.

Manual checks, added to `docs/release/MANUAL_TESTS.md`:

- With the setting off, close the main window → the Dock icon disappears.
- Quit during a meeting and cancel the confirmation → no stuck Dock icon.
  Same for each meeting alert and for the notes-folder picker.
- Click the Dock icon with no window open → Home opens.
- Open voxline from Spotlight while it's running → Home opens.
- ⌘, from another app with the menu-bar menu, and ⌘, in the app menu →
  Settings opens.
- Open the main window over a full-screen app's Space.
- Turn the setting on → the Dock icon stays after closing. Turn it off with no
  window open → the icon goes.
- A real login launch → no window and no Dock icon.
- A manual launch → Home.
- Revoke Accessibility while running → Home opens with the row showing
  missing.

## Done when

- #29 can't be reproduced through any of the paths in the issue, and a Dock
  click always shows a window.
- The main window opens and hides as specified. Settings and permissions live
  only in it.
- The unit tests above pass and the manual checks are done.
- Docs:
  - `docs/issues.md` marks #29 fixed.
  - AGENTS.md's directory map mentions `MainWindowController` and
    `ActivationPolicyController`, and the removed Settings and Permissions
    windows.
  - README mentions the Dock setting.
  - CHANGELOG gets an Unreleased entry.

## Out of scope

- History, Dictionary or Meetings as sidebar pages. The History window stays
  separate.
- Usage stats, recent dictations and shortcut reminders on Home.
- Hiding or snoozing the recording pill.
- Changes to the first-run wizard's own window, About, History, or the
  model-download window. All four are titled normal windows, so they keep
  showing the Dock icon while open, as today.
- A global shortcut to open the main window.
