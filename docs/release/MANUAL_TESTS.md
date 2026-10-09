# Manual test pass: update check

Run this checklist after the release workflow succeeds and before announcing the release.

## Setup

You'll need two installed copies of voxline:
- The *previous* released version (the one users are currently on).
- A debug build pointed at a *staging* appcast you control, for the tamper test.

Configure a staging appcast by setting `SUFeedURL` in a debug build's `Info.plist` to a file URL or a private Pages branch.

## End-to-end happy path

- [ ] Launch the previous release. Confirm `Settings → Software Updates` shows "Automatically check for updates" enabled.
- [ ] Force a scheduled check: from the menu, click "Check for updates…".
- [ ] Sparkle's modal appears, says a new version is available, shows the release notes from the appcast.
- [ ] Click Install. Sparkle downloads from the GitHub Release URL, verifies the EdDSA signature, replaces the app, relaunches.
- [ ] The new version launches without a Gatekeeper warning. Confirm via `spctl -a -v /Applications/voxline.app` (expected: `accepted source=Notarized Developer ID`).
- [ ] Settings (Software Updates toggle, hotkey, model, API keys) survived the swap.

## Gentle reminder UI

- [ ] With a known pending update on the staging feed, leave voxline running idle for >24h (or temporarily reduce `SUScheduledCheckInterval` to ~120s in a debug build for testing).
- [ ] Confirm: no modal appears. A small blue dot appears on the menu-bar icon. The menu contains an "Install update…" row near the top.
- [ ] Click "Install update…". Sparkle's modal appears (the user explicitly asked).

## Dictation-aware deferral

- [ ] With a pending update on the staging feed, start a dictation (hold the hotkey, speak).
- [ ] Mid-dictation, confirm the menu-bar badge does NOT appear and no Sparkle UI surfaces.
- [ ] Release the hotkey. Wait until the cleaned text is pasted and `state.status` returns to `.idle`.
- [ ] Within 2 minutes, do another dictation. Confirm the badge still does NOT appear (the idle window is reset).
- [ ] Wait 2+ minutes idle. Confirm the badge appears.
- [ ] Separately: with a pending update, start a dictation and click "Check for updates…" from the menu. Confirm Sparkle's modal DOES appear — manual checks bypass the deferral (this is intentional).

## Tamper test

- [ ] In the staging appcast, edit one byte of the `sparkle:edSignature` attribute on the latest `<item>`.
- [ ] Trigger a check from the previous release. Sparkle attempts to install, then aborts with a signature error.
- [ ] Confirm the failure shows up in logs: `scripts/tail-logs.sh` includes a line tagged `[updates]` describing the abort.

## Network failure

- [ ] Disable network. Click "Check for updates…". Sparkle reports an error dialog. App keeps running.
- [ ] Re-enable network. Click "Check for updates…". Normal flow resumes.

# Manual test pass: 0.4.0 platform reset

Covers what automated tests cannot: the real container migration, real AX reads, and
Sparkle running unsandboxed.

## Upgrade from 0.3.1

- [ ] Install 0.3.1 from Releases. Complete the wizard, save an API key, add
      two custom vocabulary terms, dictate three times (so history is non-empty).
- [ ] Install 0.4.0 over it (DMG drag, or Sparkle from a staging appcast). Launch.
- [ ] No wizard appears. Settings → the hotkey, provider, and model are unchanged.
- [ ] Settings → API Keys shows the saved key (no re-entry).
- [ ] Custom vocabulary still lists both terms. Show history… lists the three dictations.
- [ ] No model download happens. `ls ~/Library/Application\ Support/voxline/huggingface/models/argmaxinc/whisperkit-coreml/` lists the variant.
- [ ] `ls ~/Library/Containers/com.voxline.app/Data/Documents/` no longer contains `huggingface`.
- [ ] `scripts/tail-logs.sh --last 2m pipeline` shows a `container migration:` line with `models=true`.

## Fresh install

- [ ] `scripts/reset-local-state.sh`, launch, complete the wizard, dictate into Notes.
- [ ] `defaults read ~/Library/Preferences/com.voxline.app voxline.migration.containerMigrated` prints `1`.

## Accessibility reads work

- [ ] Run a Debug build with `VOXLINE_TRACE_LLM=1` from Xcode. Dictate into the
      middle of an existing paragraph in Notes. The trace's `textBeforeCursor`
      and `textAfterCursor` are populated (not `(nil)`).
- [ ] Select text in Notes, hold the dictation chord + command modifier, say
      "make this shorter". The selection is replaced. Repeat in Slack and in
      Gmail in Safari.

## No editable field

- [ ] Click the Finder desktop so nothing editable has focus. Dictate. The pill
      shows "No text field focused — copied"; ⌘V in Notes pastes the text.

## Diagnostics

- [ ] After three dictations, About Voxline shows a Diagnostics block with
      "Last:" and "Median of 3:" lines and non-zero transcribe/cleanup times.
- [ ] After 20 dictations, note the median total. Record it in the phase 2
      spec as the baseline.

## Entitlements and notarization

- [ ] `codesign -d --entitlements :- /Applications/voxline.app` lists exactly
      `com.apple.security.device.audio-input`, `keychain-access-groups`, and
      the signing-injected identifiers. No `app-sandbox`.
- [ ] `spctl -a -v /Applications/voxline.app` → `accepted source=Notarized Developer ID` (release build only).

## Sparkle unsandboxed

- [ ] Point a Debug build at a staging appcast with a newer version. Check for
      updates… installs and relaunches without an XPC or permission error.

## Hung target app

- [ ] Click into Slack's message box, then from Terminal run `sleep 3; kill -STOP $(pgrep -x Slack)`
      so the frozen app still owns keyboard focus (click back into Slack during the 3 s). Hold the chord, speak, release.
      voxline must not beachball for more than a second (the AX timeout is 0.5s per
      request); the pill shows "No text field focused — copied" or an error within a
      few seconds. Run `kill -CONT $(pgrep -x Slack)` afterwards.
