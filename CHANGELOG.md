# Changelog

All notable changes to voxline are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
once it reaches its first tagged release.

## [Unreleased]

## [0.3.1] - 2026-07-12

### Added

- **Command mode via a command modifier.** Hold an optional command modifier
  (default **Left Option**) together with the dictation hotkey and speak a
  command to transform the selected text. A "Command" cue appears in the pill
  while recording; the modifier is configurable (or set to **Off**) in
  Settings → Hotkey.

### Changed

- **Default dictation hotkey is now Left Shift + Left Control** (was Right Cmd +
  Right Option). Settings are persisted as a whole, so anyone who has changed
  any setting on a prior build keeps their existing hotkey; only a fresh install
  (or a never-modified configuration) picks up the new default.
- **Plain dictation never touches the clipboard.** The previous release
  auto-detected a selection by posting a synthetic Cmd+C on every recording,
  which misfired in editors that copy the whole line on an empty selection
  (VS Code default) and misrouted dictation into the transform path. Transform
  is now an explicit gesture and the selection is only read in command mode.

## [0.3.0] - 2026-07-10

### Added

- **Standalone permissions panel.** A dedicated window now surfaces the state
  of the three permissions voxline uses — Accessibility and Microphone
  (required) and Input Monitoring (recommended) — with per-item explanations
  and buttons that jump straight to the right System Settings pane. It appears
  automatically at launch when a required permission is missing, and can be
  opened any time from the new **Check Permissions…** menu-bar item. It polls
  live and closes itself once the required permissions are granted.
- **Runtime-revocation guard.** If a required permission is revoked while
  voxline is running, the panel re-appears on the granted→missing transition so
  the app never sits silently non-functional.

### Changed

- Permissions errors now show a distinct warning badge
  (`exclamationmark.triangle.fill`) in the menu bar instead of sharing the
  generic `mic.slash` error icon, and the menu adds a **Fix permissions…**
  shortcut when a permissions error is active — signalling that the problem is
  user-fixable in System Settings.

## [0.2.5] - 2026-07-10

### Added

- **Transform selected text by voice.** Highlight text in any app, press the
  dictation hotkey, and speak a rewrite/restructure command — "make this a
  bullet list", "make this cleaner", "make this shorter". voxline rewrites the
  selection in place and leaves it as a normal ⌘Z-undoable edit. When no text
  is selected, the hotkey dictates as before. Transforms open the same
  post-dictation refinement pill for quick follow-ups.

### Fixed

- Text insertion now prefers ⌘V clipboard paste over synthetic typing, so
  dictation and transforms land reliably in apps (such as Notes) that ignore
  synthetic keystrokes. Under the App Sandbox the previous AX-based
  paste-eligibility check always failed and forced the unreliable typing path.

[Unreleased]: https://github.com/tfredricks/voxline/compare/v0.3.1...HEAD
[0.3.1]: https://github.com/tfredricks/voxline/releases/tag/v0.3.1
[0.3.0]: https://github.com/tfredricks/voxline/releases/tag/v0.3.0
[0.2.5]: https://github.com/tfredricks/voxline/releases/tag/v0.2.5
