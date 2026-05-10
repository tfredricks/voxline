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
