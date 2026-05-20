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
