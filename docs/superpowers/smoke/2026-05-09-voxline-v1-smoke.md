# voxline v1 Smoke Pass

**Date:** 2026-05-09 (planned)  •  **Actual run date:** _____________
**Builder:** _____________
**Build:** main @ _____________ (post-Plan-5 merge)
**Hardware:** _____________ (e.g. MacBook Air M2, 16 GB)
**macOS version:** _____________ (e.g. 26.4)
**Reference plans:** Plans 1–5 in `docs/superpowers/plans/`

---

## How to use this document

Walk every checkbox on the target Mac. Mark each line PASS / FAIL / SKIP and note any
observations. If anything FAILs, file a follow-up task; do not tag `voxline-v1-shipped`.
SKIP is allowed only when the test depends on hardware you don't have on hand
(e.g. external USB mic). Note the reason inline.

---

## 1. Setup smoke (fresh install)

- [ ] Delete `~/Library/Containers/com.voxline.voxline/`. Build + Run from Xcode.
- [ ] Wizard appears centered, non-closable (no red close button).
- [ ] **Welcome step**: text reads correctly, Continue advances.
- [ ] **Permissions step**: grant Microphone (TCC dialog), Accessibility (System Settings opens to the right pane), Input Monitoring (TCC dialog). Each row's badge flips green within ~2s of granting. Continue button enables only after all three are green.
- [ ] **API Key step**: provider picker switches between Anthropic and OpenAI; the secure field swaps accordingly. Paste a real key. Click "Test connection" → ✓ Connected appears. Continue advances.
- [ ] **Model Download step**: progress bar advances. Continue button is disabled until status reaches `.idle`. (If you've already downloaded large-v3-turbo from a previous install, this step shows "Preparing…" and finishes faster.)
- [ ] **Done step**: shows "Hold **Left Ctrl + Left Option**…". Click "Get started".
- [ ] Wizard closes; menu icon goes to `mic`.
- [ ] Quit voxline. Relaunch. Wizard does NOT appear; app starts with mic icon visible.

## 2. Hotkey + dictation smoke

In each target app, hold **Left Ctrl + Left Option**, dictate, release. Cleaned text should paste into the focused field. No leading/trailing modifier-key chatter.

- [ ] **TextEdit** (new untitled doc): "Hello uh world" → "Hello world." (or close).
- [ ] **Slack** (DM compose): dictate. Cleaned text appears. Conversation is NOT accidentally Cmd-Sent.
- [ ] **Apple Mail** (compose): dictate a short message. Output is professionally formatted (Mail mode prompt fires).
- [ ] **Cursor** (any file): dictate "let x equal 42". Output preserves code-adjacent style.
- [ ] **Safari** (any text input — search, address bar, textarea): dictate. Pastes.
- [ ] **Chrome** (textarea on any site): dictate. Pastes.
- [ ] **Notes**: dictate. Pastes.
- [ ] **Terminal** (or iTerm): dictate. Pastes (no shell interpretation; cursor not advanced past pasted text).

## 3. Settings smoke

### General tab

- [ ] **Hotkey**: "Record chord…" → press Right Cmd then Right Shift → display updates to "Right Cmd + Right Shift". Save. Hold new chord in TextEdit, dictate. Pastes. Restore default chord (Left Ctrl + Left Option) and Save.
- [ ] **Microphone**: if a USB mic is available, plug it in. Settings → General. Picker lists it. Pick it. Save. Dictate; verify via System Settings → Sound that voxline used the picked mic (or speak only into the external mic). Switch back to System default. (SKIP if no external mic.)
- [ ] **Speech recognition model**: switch to small.en. Save. First dictation pays a download (progress visible in menu bar). Subsequent dictations are fast. Switch back to large-v3-turbo (already cached, prewarm only).

### API Keys tab

- [ ] **Test connection** with a valid key → ✓ Connected.
- [ ] Replace key with garbage → Test → ✗ "API key was rejected by the provider." (or similar). Restore the real key.

### Modes tab

- [ ] Click "Add from running apps" → pick TextEdit. New row appears with bundle ID `com.apple.TextEdit`.
- [ ] Edit prompt to "ALL CAPS THE TRANSCRIPT." Save. Dictate in TextEdit; output is uppercase.
- [ ] Delete the TextEdit mode (select row, click −). Save. Dictate in TextEdit again; output uses the `*` fallback (lowercase).

## 4. Pause/Resume smoke

- [ ] Menu bar → "Pause voxline". Hold the chord; nothing happens (no pill, no status change).
- [ ] Menu bar → "Resume voxline". Chord works again on the next press.

## 5. Error-state smoke

- [ ] **No API key**: Settings → API Keys → clear both keys → Save. Dictate. Menu icon goes red; clicking shows "No API key configured. Open Settings → API Keys to set one." Restore a key. Next dictation succeeds.
- [ ] **Invalid API key**: Settings → API Keys → set both keys to garbage → Save. Dictate. Menu shows "API key was rejected by the provider." Restore valid key.
- [ ] **No-network**: Disable Wi-Fi (or set provider URL to unreachable). Dictate. Menu shows "Network error: …" within 5–30s. Re-enable Wi-Fi. Next dictation succeeds.
- [ ] **Mic-denied**: System Settings → Privacy & Security → Microphone → revoke voxline. Dictate. Menu shows "No audio captured. Check that Microphone permission is granted and the input device isn't muted." Restore mic permission. Next dictation succeeds.
- [ ] **Accessibility-revoked**: System Settings → revoke Accessibility for voxline. Within 2s the menu shows the revocation error. Restore. Within 2s the chord works again (no relaunch needed).
- [ ] **Wizard download retry**: with a fresh install, disable Wi-Fi at the Permissions step. Continue to Model Download — error message appears with Retry button. Re-enable Wi-Fi. Click Retry. Download resumes. Continue to Done.
- [ ] **Transcription fail**: (hard to trigger naturally; SKIP unless you can reliably reproduce. If you can, the menu should show "Transcription failed. Try again or pick a different model in Settings → General.")

## 6. Clipboard preservation

- [ ] Copy "MARKER1" in TextEdit. Dictate "hello". After paste completes, ⌘V into TextEdit again → "MARKER1" returns.
- [ ] Copy a small image (Preview → Edit → Copy). Dictate. After paste, ⌘V into another app → image returns.
- [ ] Copy a file from Finder (which uses promised types). Dictate. Expected: voxline refuses to clobber and surfaces an error rather than silently destroying the clipboard.

## 7. Edge cases

- [ ] **Very short hold** (chord + immediate release, < 200ms): pill flashes briefly; no transcript or "empty audio" handling. State returns to idle.
- [ ] **Very long hold** (60s+): max-duration fail-safe fires. Recording finalizes regardless of chord state. Transcript appears.
- [ ] **Rapid double-press**: hold, release, hold again immediately. Each cycle produces its own transcript.
- [ ] **Modifier rollover**: hold the chord, then press a third modifier (e.g. Shift) without releasing the chord. Recording continues. Release one of the chord modifiers. Recording finalizes.
- [ ] **App focus change mid-recording**: hold chord, click a different app, keep holding. App-deactivation guard fires (Plan 1 fail-safe); recording finalizes defensively.

---

## Outcome

- **Overall:** PASS / FAIL / PASS-WITH-ISSUES (circle one)
- **Issues found** (file path, severity, brief repro):
  - _____________
  - _____________
  - _____________
- **If PASS:** create tag `voxline-v1-shipped` at the smoke-pass SHA:
  ```bash
  git tag voxline-v1-shipped
  ```
- **If FAIL or PASS-WITH-ISSUES:** open follow-up tasks. Do NOT tag.
