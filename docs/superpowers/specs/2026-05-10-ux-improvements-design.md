# UX Improvements — Design Spec

**Date:** 2026-05-10
**Owner:** todd124@gmail.com
**Status:** Design — pending implementation plan

## Background

voxline runs as a menu-bar-only agent (`LSUIElement = true`) with no Dock icon. The current menu-bar dropdown has Pause/Resume, Settings…, Debug (DEBUG builds only), and Quit. The app has no About dialog, no in-app path to file bug reports or feedback, and no Launch-at-Login toggle. Users who open Settings cannot easily Cmd-Tab back to it because voxline is invisible to the Dock and app switcher.

The Thaw menu-bar app (https://github.com/stonerl/Thaw) handles two of these issues well: it shows a Dock icon while its options pane is open (making the window findable), and it provides an About dialog. We want the same affordances in voxline, plus a Launch-at-Login toggle and a path to GitHub Issues for bug reports and feedback.

## Goals

1. **Make voxline's user-facing windows findable** via Dock icon and Cmd-Tab while they are open.
2. **Add a discoverable About dialog** with version, attribution, and links to the project's GitHub repo, bug template, and feedback template.
3. **Add a Launch-at-Login toggle** in Settings → General that handles the macOS approval flow gracefully.
4. **Keep voxline silent in the Dock** the rest of the time — no regression to the always-Dock-icon experience.

## Non-goals

- No Sparkle / auto-update integration.
- No Help submenu beyond the About dialog (logs viewer, privacy page, etc. are deferred).
- No quick-mode-switch in the menu bar dropdown.
- No re-run-Welcome menu item.
- No notifications, status-aware menu header, or other dropdown-content changes.
- No changes to capture, transcription, LLM, or output code paths.

## High-level approach

Three independent additions, each isolated to its own component:

1. A `WindowVisibilityCoordinator` that flips `NSApp.activationPolicy` between `.accessory` and `.regular` based on whether any user-facing window is visible.
2. An `AboutWindowController` + `AboutView` mirroring the existing `*WindowController` pattern, fed by a small `SupportLinks` URL builder for the GitHub Issues buttons.
3. A `LoginItemService` wrapping `SMAppService.mainApp`, surfaced as a toggle in `GeneralSettingsView` with an inline approval hint.

`AppDelegate` wires them together. `MenuBarContent` gains an "About voxline" item.

---

## 1. Dock-on-window (activation policy switching)

### Component

`WindowVisibilityCoordinator` — `@MainActor`, owned by `AppDelegate`. Maintains an `Int` count of visible user-facing windows.

### Behavior

- Observes `NSWindow.didBecomeVisibleNotification` and `NSWindow.willCloseNotification` on `NotificationCenter.default`.
- For each notification, applies a classification rule:
  - **Excluded** (HUD-style, never trigger Dock): `RecordingPillWindow`, `ModelDownloadWindow`. Identified by class.
  - **Included** (everything else that is `.titled` and not floating-level): Settings (SwiftUI scene), `AboutWindowController`'s window, `FirstRunWindowController`'s window, `DebugWindowController`'s window.
- Increments on visible-notify for an included window; decrements on willClose for a tracked window.
- When count transitions 0 → ≥1: `NSApp.setActivationPolicy(.regular)` then `NSApp.activate()`.
- When count transitions ≥1 → 0: `NSApp.setActivationPolicy(.accessory)`.

### Edge cases

- **Initial state mismatch:** at startup the coordinator scans `NSApp.windows` once and seeds the counter from currently-visible included windows (covers the case where the wizard window is shown before the coordinator initializes).
- **Window reused across show/hide cycles:** tracked by object identity (`ObjectIdentifier`) in a set so a single window cannot double-increment.
- **Settings window class is private SwiftUI:** identification works by exclusion-list rather than inclusion-list — any `NSWindow` not in the excluded class set and matching the "titled, normal level" check counts.
- **Activation race:** `setActivationPolicy(.regular)` followed by `activate()` is required for the focus ring and Dock bounce to land on the right window. Already done in `MenuBarContent` for `openSettings()`; the About-open path replicates the pattern.

### Considered alternatives

- **Per-window register/unregister calls.** Every window controller would learn about activation policy; rejected for coupling.
- **Polling `NSApp.windows` in a Timer.** Wasteful and slow to react; rejected.

### Testing

- Inject a `NotificationCenter` into the coordinator. Assert counter behavior on simulated `didBecomeVisible` / `willClose` notifications for stub `NSWindow` subclasses (one excluded, one included).
- Assert `setActivationPolicy(.regular)` is called exactly once on 0 → 1, and `setActivationPolicy(.accessory)` on ≥1 → 0, via an injected `ActivationPolicyController` protocol the coordinator depends on.

---

## 2. About dialog

### Components

- **`AboutWindowController`** — `NSWindowController` hosting an `NSHostingView<AboutView>`. Mirrors the pattern of `FirstRunWindowController`, `ModelDownloadWindow`, `RecordingPillWindow`. Lazily instantiated by `AppDelegate` on first open.
- **`AboutView`** — SwiftUI view rendering the layout below.
- **`SupportLinks`** — pure-functions URL builder (see §3).

### Window configuration

- Size: 320 × 420, non-resizable.
- Style mask: `[.titled, .closable]`.
- Title: "About voxline".
- Centered on first show; remembers position via standard NSWindow autosave.

### Layout (top to bottom, centered)

1. App icon, 64×64 (loaded from `NSApp.applicationIconImage`).
2. "voxline" — `.title`, `.semibold`.
3. "Version 1.0 (1)" — `.subheadline`, `.secondary`. Version assembled from `CFBundleShortVersionString` + `CFBundleVersion`.
4. Tagline (two lines, centered, `.secondary`):
   > "Local-first dictation for Mac.
   > Audio never leaves your Mac."
5. Three full-width buttons, stacked, with `.bordered` style:
   - "Visit GitHub" → opens `SupportLinks.repoURL`.
   - "Report a Bug…" → opens `SupportLinks.bugReportURL(env:)`.
   - "Send Feedback…" → opens `SupportLinks.feedbackURL(env:)`.
6. Footer (small, `.tertiary`):
   - "Built with WhisperKit"
   - "© 2026 Todd Fredricks"

Buttons call `NSWorkspace.shared.open(url)`.

### Trigger

- New `Button("About voxline")` in `MenuBarContent`, placed above Quit. Calls a closure passed in from `voxlineApp`, same pattern as `openDebugWindow`.
- Standard NSApp About menu item (visible when activation policy is `.regular`) is wired to open the same window. Implemented by overriding `NSApp.delegate`'s response to the standard About action so the menu item routes through `AboutWindowController.show()` instead of `orderFrontStandardAboutPanel`.

### Considered alternatives

- **SwiftUI `Window` scene declared in `App` body.** Cleaner trigger via `openWindow(id:)` and automatic single-window lifecycle. Rejected for inconsistency with the existing `*WindowController` pattern that the wizard, model-download, and pill windows already use.
- **`orderFrontStandardAboutPanel` with custom `Credits` AttributedString.** Smaller code footprint but no real buttons (only inline links), and visual style is locked to Apple's. Rejected because the Report-a-Bug and Send-Feedback affordances are first-class features here, not links buried in credits.

### Testing

- `AboutView` rendered in SwiftUI Preview for visual check; no automated UI test.
- Manual smoke: open About from menu bar, click each button, verify the right URL opens with the right prefilled body (see §3 testing).

---

## 3. SupportLinks (GitHub Issues URL builder)

### Component

`SupportLinks` — `enum` (or struct with static members), pure functions, no dependencies beyond Foundation and the Bundle.

### API

```swift
enum SupportLinks {
    static let repoURL: URL  // https://github.com/tfredricks/voxline

    static func bugReportURL(env: SupportEnvironment) -> URL
    static func feedbackURL(env: SupportEnvironment) -> URL
}

struct SupportEnvironment {
    let appVersion: String     // "1.0"
    let buildNumber: String    // "1"
    let osVersion: String      // "14.5 (23F79)"
    let whisperModel: String   // current model name
    let micDevice: String?     // current device name, or nil
}
```

### URL format

Bug:
```
https://github.com/tfredricks/voxline/issues/new
  ?template=bug.yml
  &body=<URL-encoded environment block>
```

Feedback: same shape, `template=feedback.yml`.

### Environment block (URL-encoded body)

```
**Environment**
- voxline version: 1.0 (1)
- macOS: 14.5 (23F79)
- Whisper model: large-v3-turbo
- Mic device: MacBook Pro Microphone
```

The body uses Markdown so it renders cleanly when GitHub's template inserts the rest.

### Repo prerequisites (not Swift)

The implementation plan must include a step to add issue templates to the repo:

- `.github/ISSUE_TEMPLATE/bug.yml` — title prefix "Bug:", standard fields (steps to reproduce, expected, actual, logs).
- `.github/ISSUE_TEMPLATE/feedback.yml` — title prefix "Feedback:", free-form description.

Both templates accept a free-text body so the prefilled environment block lands in the issue.

### Considered alternatives

- **Inline URL construction at the call site.** Two duplications and a less-testable surface. Rejected.
- **`mailto:` for feedback.** Friendlier to non-technical users but bypasses public issue tracking the user explicitly asked for. Rejected per Q3 answer.

### Testing

- Pure unit tests asserting the exact URL string for a given `SupportEnvironment`, including URL encoding of the body.
- One test per template variant.

---

## 4. Launch at Login

### Components

- **`LoginItemService`** — wraps `SMAppService.mainApp`. Maps `SMAppService.Status` to a local enum.
- **`GeneralSettingsViewModel`** — gains `launchAtLogin: Bool` and `loginItemStatus: LoginItemService.Status`.
- **`GeneralSettingsView`** — gains a "Startup" section.

### `LoginItemService` API

```swift
@MainActor
final class LoginItemService {
    enum Status { case enabled, disabled, requiresApproval, unsupported }

    var status: Status { get }       // reads SMAppService.mainApp.status
    func setEnabled(_ enabled: Bool) throws
}
```

`setEnabled(true)` calls `SMAppService.mainApp.register()`; `setEnabled(false)` calls `.unregister()`. Both are synchronous and may throw; the ViewModel surfaces the throw as a transient error and re-reads `status` regardless (the status is the source of truth).

### UI

A new "Startup" section is added to `GeneralSettingsView`, placed at the top above "Hotkey":

```
Startup
  [✓] Launch voxline at login
      ⓘ Approval required — open Login Items in System Settings
```

The hint row appears only when `loginItemStatus == .requiresApproval`. It is rendered as a `Button` styled as a link; clicking it opens
`x-apple.systempreferences:com.apple.LoginItems-Settings.extension`
via `NSWorkspace.shared.open(url)`.

### ViewModel wiring

- On init: read `service.status`, set `launchAtLogin` from it (`.enabled` → true; everything else → false).
- Toggle setter: call `service.setEnabled(newValue)`, then re-read `service.status` and update both `launchAtLogin` and `loginItemStatus`. If the call throws, leave the toggle reflecting actual status (so a failed register reverts visually).
- Refresh on window-becomes-key: a `.task` modifier on the view re-reads status when the Settings window regains focus, so an off-window approval in System Settings reflects back into the toggle without restart.

### Considered alternatives

- **Direct `SMAppService.mainApp` calls in the ViewModel.** Simpler one-time, but the wrapper lets us inject a fake in `GeneralSettingsViewModel` tests and centralizes the `Status` mapping. Wrapper wins.
- **Modal alert on `.requiresApproval`.** More intrusive than the inline hint and produces an annoying interruption every time the toggle is flicked. Rejected per Q4 answer.

### Testing

- `LoginItemService`: status mapping unit-tested by stubbing the SM status enum (the wrapper exposes a seam for the test).
- `GeneralSettingsViewModel`: tested with a fake `LoginItemService` — toggle on/off updates `launchAtLogin` and `loginItemStatus`; `requiresApproval` keeps `launchAtLogin == false`.
- Manual verification: register, then revoke approval in System Settings, observe the inline hint reappear when the Settings window regains focus.

---

## 5. Integration

### `AppDelegate.applicationDidFinishLaunching`

Adds:
1. `windowVisibilityCoordinator = WindowVisibilityCoordinator(); windowVisibilityCoordinator.start()`
2. (No eager About instantiation — lazy on first open.)

### `voxlineApp.body`

`MenuBarContent` gains an `openAboutWindow: () -> Void` parameter wired in `voxlineApp` to call `delegate.aboutWindow.show()`. `AppDelegate` lazily creates `aboutWindow: AboutWindowController?` on first call.

### `MenuBarContent`

New button between Settings/Debug and Quit:

```swift
Divider()
Button("About voxline") { openAboutWindow() }
```

No keyboard shortcut (avoids collision with anything else).

### Files added

- `voxline/MenuBar/WindowVisibilityCoordinator.swift`
- `voxline/UI/AboutWindowController.swift`
- `voxline/UI/AboutView.swift`
- `voxline/Settings/SupportLinks.swift`
- `voxline/Settings/LoginItemService.swift`
- `.github/ISSUE_TEMPLATE/bug.yml`
- `.github/ISSUE_TEMPLATE/feedback.yml`

### Files modified

- `voxline/voxlineApp.swift` — instantiate coordinator + about controller, pass closure to `MenuBarContent`.
- `voxline/MenuBar/MenuBarContent.swift` — add About button.
- `voxline/Settings/GeneralSettingsView.swift` — add Startup section.
- `voxline/Settings/GeneralSettingsViewModel.swift` — add `launchAtLogin`, `loginItemStatus`, service dependency.
- `voxline/Info.plist` — no changes (LSUIElement stays true; runtime activation policy override is what makes Dock toggling work).

### Capabilities / entitlements

`SMAppService.mainApp` requires the app to be properly signed and notarized for production but works in development with ad-hoc signing. No new entitlements required for `SMAppService.mainApp` (only for `SMAppService.daemon` / `.agent`, which we are not using).

---

## Manual smoke test matrix

| Scenario | Expected |
|---|---|
| Open Settings via menu | Dock icon appears, app shows in Cmd-Tab |
| Close Settings | Dock icon disappears within ~1s |
| Open Settings + About simultaneously | Dock icon stays through both |
| Close About, leave Settings open | Dock icon stays |
| Close last window | Dock icon disappears |
| Wizard on first run | Dock icon appears for wizard |
| Recording pill visible during dictation | Dock icon does **not** appear |
| Model download window on launch | Dock icon does **not** appear |
| Click "Visit GitHub" in About | Opens repo in browser |
| Click "Report a Bug…" | Opens GitHub Issues with bug template + env block prefilled |
| Click "Send Feedback…" | Opens GitHub Issues with feedback template + env block prefilled |
| Toggle Launch at Login → on (first time) | Status reads `requiresApproval`, inline hint appears |
| Click hint | Opens System Settings → Login Items |
| Approve in System Settings, return to voxline Settings | Hint disappears, toggle stays on |
| Quit and re-login to macOS | voxline auto-launches |
| Toggle off | App is removed from login items |

## Out-of-scope / deferred

The brainstorm surfaced several other UX improvements (status-aware menu header, Help submenu, quick mode switch, re-run Welcome, Sparkle updates, notifications). They are not part of this spec and will be evaluated separately.
