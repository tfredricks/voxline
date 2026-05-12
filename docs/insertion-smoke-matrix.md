# Text Insertion Smoke Matrix

Use this matrix to decide when feature #1 in `docs/features.md` is complete.
Each app should be tested with a normal editable field, with an existing
clipboard value copied before dictation. After insertion, paste again to verify
the original clipboard value was restored.

Result values:

- `PASS`: Text appeared in the focused field and the clipboard was restored.
- `PASS-UNVERIFIED`: Text appeared, but voxline could not confirm insertion through Accessibility.
- `FALLBACK`: Text appeared through Accessibility insertion or direct typing after clipboard paste was rejected.
- `FAIL`: Text did not appear, appeared in the wrong place, or the clipboard was not restored.
- `UNSUPPORTED`: The target field intentionally rejects automation, such as secure password fields.

| App / Field | Result | Strategy shown in Debug | Notes |
| --- | --- | --- | --- |
| TextEdit document |  |  |  |
| Apple Mail compose body |  |  |  |
| Slack message composer |  |  |  |
| Cursor editor |  |  |  |
| Safari address/search field |  |  |  |
| Safari textarea |  |  |  |
| Chrome address/search field |  |  |  |
| Chrome textarea |  |  |  |
| Notes note body |  |  |  |
| Terminal prompt |  |  |  |
| iTerm prompt |  |  |  |
| VS Code editor |  |  |  |
| Google Docs document body |  |  |  |
| Notion page body |  |  |  |
| ChatGPT prompt box |  |  |  |
| Password / secure text field |  |  | Expected `UNSUPPORTED`; do not paste sensitive text during this check. |

Feature #1 can be marked done when the normal editable-field targets above are
`PASS`, `PASS-UNVERIFIED`, or documented `FALLBACK`, and any failures have an
explicit limitation or follow-up issue.

## Context-aware formatting (feature #11)

For each target app, run a single dictation and confirm the `AppLog.context`
debug line matches the expected shape. Filter Console.app with
`subsystem == "com.voxline.app" AND category == "context"`, or set
`VOXLINE_TRACE_LLM=1` to dump the formatted prompt to stdout.

Legend: `yes` expected present, `maybe` framework-dependent (Catalyst/Electron
often empty), `—` not applicable, `suppressed` value-bearing field withheld.

| App                           | App line | Window | Field         | Before/after | Vocabulary | Result |
| ----------------------------- | -------- | ------ | ------------- | ------------ | ---------- | ------ |
| Apple Mail compose body       | yes      | yes    | AXTextArea    | yes          | if set     |        |
| Slack message composer        | yes      | maybe  | AXTextArea    | maybe        | if set     |        |
| Cursor editor                 | yes      | yes    | AXTextArea    | maybe        | if set     |        |
| Safari address/search field   | yes      | yes    | AXTextField   | yes          | if set     |        |
| Notes note body               | yes      | yes    | AXTextArea    | yes          | if set     |        |
| Terminal prompt               | yes      | maybe  | AXTextArea    | maybe        | if set     |        |
| Password / secure text field  | yes      | yes    | secure        | suppressed   | if set     |        |

Expectations:

- **App line** present whenever a frontmost app is detected (almost always).
- **Window** present when the focused element exposes `kAXWindowAttribute`
  with a non-empty title; can be empty in Terminal, some Electron windows.
- **Field** present when AX returns a role; `secure` for password fields.
  Catalyst apps (Outlook, Discord) may resolve through the app-level AX
  fallback added in `9668bf2`.
- **Before/after** present when AX exposes `kAXValueAttribute` and a
  selected-text range. Often empty in web textareas and Electron apps.
- **Vocabulary** present iff the user saved any global terms in Settings →
  Custom vocabulary.
- **Secure-field row** must show value-bearing lines suppressed (no
  before/after cursor, no selected text). Validate by dictating into a
  1Password or system login screen; confirm Console.app shows the captured
  context but excludes any value content.

## Settings (single-page redesign — 2026-05-10)

| State                              | Expected                                                                         |
| ---------------------------------- | -------------------------------------------------------------------------------- |
| Fully configured                   | Strip = green ● Ready; mic / model / provider chips show ✓                       |
| No active provider key             | Strip = orange ● Setup needed; provider chip has no ✓                            |
| Selected mic UID disconnected      | Strip = orange ● Setup needed; mic row shows "(disconnected) previously selected" |
| Whisper model not cached           | Strip = orange; recognition picker shows "to download · N MB" (no ✓ on chip)     |
| Switch provider with both keys     | Disclosure label updates to other provider; both keys retained                   |
| Mic meter responds to speech       | Bar moves green→yellow→red as level rises                                        |
| Window closed during meter         | System mic indicator clears (engine stopped)                                     |
| Window closed during recording     | Meter stopped before recording started — no contention                           |
| Status chip click → scroll         | Clicking model/provider chip scrolls form to that section                        |

## Dictation history window (feature #16, 2026-05-11 evolution)

Smoke the standalone history window. Replaces the previous "Recent dictations"
submenu check.

| Case                                        | Expected                                                                                                |
| ------------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| Open via "Show history…"                    | Window titles "Voxline History", 720×480 default, table with Time/Mode/App/Preview columns              |
| Empty history                               | Empty-state placeholder centered; "Clear history" disabled                                              |
| Dictate into Slack                          | Top row shows `Slack` in Mode column, `Slack` in App column                                             |
| Dictate into Mail                           | Row shows `Mail` in Mode, `Mail` in App                                                                 |
| Dictate into Cursor                         | Row shows `Cursor` in Mode, `Cursor` in App                                                             |
| Dictate into Safari (unlisted app)          | Row shows `Default` in Mode (wildcard), `Safari` in App                                                 |
| Click any row                               | Clipboard receives `cleanedText`; "Copied" toast fires for ~1.2s                                        |
| Click "Clear history"                       | Table replaced by empty state; no confirmation prompt                                                   |
| Quit + relaunch                             | Existing rows persist                                                                                   |
| Manually pre-seed UserDefaults old-shape JSON under `voxline.history.dictations` (3 fields only) | After relaunch, rows render with `—` in Mode and App columns; no crash |
| Open History twice without closing          | Existing window is brought forward (no second window)                                                   |
