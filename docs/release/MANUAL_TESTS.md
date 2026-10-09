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

- [ ] Maintainers: if this Mac ever ran an unsandboxed dev build, first wipe `~/Library/Application Support/voxline` and the `com.voxline.app` domain (`defaults delete ~/Library/Preferences/com.voxline.app`), or the migration will skip your real data as "destination already exists".
- [ ] Install 0.3.1 from Releases. Complete the wizard, save an API key, add
      two custom vocabulary terms, dictate three times (so history is non-empty).
- [ ] Install 0.4.0 over it (DMG drag, or Sparkle from a staging appcast). Launch.
- [ ] No wizard appears. Settings → the hotkey, provider, and model are unchanged.
- [ ] Settings → API Keys shows the saved key (no re-entry).
- [ ] Custom vocabulary still lists both terms. Show history… lists the three dictations.
- [ ] No model download happens. `ls ~/Library/Application\ Support/voxline/huggingface/models/argmaxinc/whisperkit-coreml/` lists the variant.
- [ ] `ls ~/Library/Containers/com.voxline.app/Data/Documents/` no longer contains `huggingface`.
- [ ] `scripts/tail-logs.sh --last 2m pipeline` shows a `container migration:` line with `models=true`.
- [ ] The first dictation after the upgrade is not delayed by a 30 s–2 min model compile (the ANE cache moved with the rest).
- [ ] Numbers: select a cell (not editing it), dictate. The text lands in the cell, as in 0.3.1. Repeat in Excel.

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
      voxline must not beachball for more than a few seconds (each AX request is capped
      at 0.5 s and a dictation makes several); the pill shows "No text field focused — copied"
      or an error within a few seconds. Run `kill -CONT $(pgrep -x Slack)` afterwards.
- [ ] Repeat with text selected and the command chord: same bound.

# Manual test pass: 0.5.0 transcription engine

Covers what automated tests cannot: real speech engines, real audio hardware,
real full-screen Spaces, and real network failure. Use an Apple Silicon Mac and
a build from `scripts/build-local.sh`, with Anthropic or OpenAI cleanup
configured. Keep `scripts/tail-logs.sh --last 2m pipeline` open in a terminal;
several items below check it.

## Live text in the pill

- [ ] On the default engine (Whisper), hold the chord in Notes and speak 15–20
      words. Within about a second the pill shows your words under the
      waveform: settled text bright, the last few words dimmer and still
      changing.
- [ ] Release. The pill reads "Transcribing…", then "Cleaning up…" with the
      transcript's last two lines dimmed below it, then "Inserting…", and
      disappears as the text lands.
- [ ] Select Apple Speech and repeat. Live text appears while you speak, and
      the text lands almost immediately after release.

## Pill placement

- [ ] With the mouse on the main display, the pill is centered, just above the
      bottom edge of the screen.
- [ ] Dictate into a field near the bottom or right edge of the screen. The
      pill is fully visible.
- [ ] Put a browser in macOS full screen (its own Space), click into a text
      field, and dictate. The pill appears over the full-screen app.
- [ ] With a second display attached, move the mouse to it and dictate. The
      pill appears bottom-center on that display, not the first.

## Esc cancels

- [ ] While recording: hold the chord, speak, press Esc without releasing.
      The pill says "Cancelled", the stop blip does not play, and nothing is
      inserted or added to History. Release the chord: nothing happens. Hold
      it again straight away: a new dictation starts normally.
- [ ] Esc is swallowed only while voxline is busy. In Safari open the find bar
      (⌘F), then dictate and press Esc mid-recording: the find bar stays open.
      Once idle, press Esc: the find bar closes.
- [ ] While transcribing: on Whisper, dictate three to five words and press Esc
      the instant you release (the window is under a second, so repeat until
      the pill reads "Transcribing…" when you press). The pill says
      "Cancelled", nothing is inserted, and no text appears later (wait 5 s).
- [ ] While cleaning up: dictate about a minute of speech and press Esc when
      the pill reads "Cleaning up…". The pill says "Cancelled", nothing is
      inserted, and no text appears later. History has a new entry whose
      cleaned text equals the raw transcript, and the menu bar's "Retry last
      dictation" is enabled.
- [ ] During insert: press Esc while the pill reads "Inserting…" (best effort;
      the window is short). Esc is ignored and the text lands exactly once.
- [ ] After every cancel above, a new dictation starts and finishes normally.

## Retry

- [ ] Select Whisper, turn Wi-Fi off, and dictate into Notes. Transcription
      works on-device, then cleanup fails: the pill shows the error and a Retry
      button, and the raw transcript is on the clipboard.
- [ ] Turn Wi-Fi on and click Retry within 8 s. The cleaned text lands in
      Notes, and the cursor never left the note (the pill did not take focus).
- [ ] Repeat the failure and let the 8 s pass. The pill goes away, and the
      menu bar's "Retry last dictation" is enabled. Focus a field in another
      app (Slack), choose it, and the cleaned text lands there, formatted for
      that app.
- [ ] On a fresh launch, "Retry last dictation" is disabled.
- [ ] Select text, hold the chord and the command modifier, and speak a
      command with Wi-Fi off. The error appears without a Retry button.

## Microphone disconnected

- [ ] Settings → General → Microphone: pick a USB mic, not the built-in one.
      Hold the chord, speak half a sentence, and unplug the mic while still
      holding. The pill says "Microphone disconnected — stopped recording" and
      what you said before the unplug is transcribed and inserted. Switch the
      input back and confirm the next dictation works.
- [ ] If that toast never appears, note the mic and macOS version in the test
      log instead of failing the pass: the interruption only fires when the
      audio engine actually stops, and some devices keep it running.

## Switching engines

- [ ] Settings → General → Recognition → Engine lists "Apple Speech —
      on-device, fastest", "Whisper — on-device", and "OpenAI — cloud, audio
      leaves your Mac". A fresh install has Whisper selected, and the Whisper
      model picker shows only while Whisper is selected.
- [ ] Select Apple Speech and dictate in Notes. Text lands. Select Whisper and
      dictate again. Text lands.
- [ ] Choose a Whisper model that is not downloaded yet (for example small.en
      if only large-v3 turbo is cached). The menu bar shows download progress,
      and a dictation started meanwhile waits for the download. After it
      finishes, dictate: text lands.
- [ ] Select OpenAI with no OpenAI key stored. A caption says audio is sent to
      OpenAI with your key, and a warning says no key is stored.
- [ ] Add an OpenAI key (in Recognition when cleanup is not using OpenAI;
      otherwise in API Keys) and dictate. Live text appears a phrase at a time
      and the final text is inserted.
- [ ] `scripts/tail-logs.sh --last 5m metrics` names the engine for each
      dictation above.
- [ ] Quit and relaunch: the selected engine is unchanged. Reset to Defaults
      selects Whisper.

## OpenAI fallback

- [ ] With OpenAI selected and cleanup on Anthropic, change the last character
      of the stored OpenAI key so it is invalid, and dictate. The dictation
      still completes with a correct transcript, and the pill shows "Cloud
      transcription failed — used on-device". Restore the key.
- [ ] With a valid key, turn Wi-Fi off and dictate five seconds of speech. The
      on-device fallback transcribes it (the `pipeline` log notes the
      fallback). Cleanup then fails for lack of network, so you get the Retry
      error with the correct transcript on the clipboard. Turn Wi-Fi on and
      click Retry to finish.
- [ ] `find ~/Library/Application\ Support/voxline -name '*.wav'` prints
      nothing: the fallback kept the audio in memory only.

## First-run wizard

- [ ] `scripts/reset-local-state.sh --keep-model` (this wipes saved API keys),
      then launch. With Whisper's model cached, the wizard never shows the
      "Speech engine" step.
- [ ] `scripts/reset-local-state.sh` with no flags, Wi-Fi off, then launch. The
      "Speech engine" step shows the failed download and has a "Quit Voxline"
      button that quits the app. Turn Wi-Fi on, relaunch, and confirm the
      download completes and the wizard continues.

## Five-minute cap

- [ ] Hold the chord and keep talking (reading aloud works). Past 60 s the
      recording continues and the pill shows the elapsed time as `1:00`,
      `1:01`, and so on.
- [ ] At 5:00 recording stops on its own, the text is transcribed, cleaned up,
      and inserted, and the pill says "Stopped at 5 minutes".
- [ ] Press Esc at about two minutes. The recording is cancelled cleanly.

## Audio edge cases

- [ ] Tap the chord quickly (under half a second) ten times. No "No audio
      captured" error appears; the pill just goes away.
- [ ] End a sentence on a distinct word ("…and send it to Dana") and release
      the chord the instant you finish it. Repeat five times: the last word is
      never clipped.

## No regressions

- [ ] Select text in Notes, hold the chord and the command modifier, say "make
      this shorter". The selection is replaced.
- [ ] With nothing editable focused, dictate. The pill shows "No text field
      focused — copied".
- [ ] Show history… lists these dictations with the raw transcript next to the
      cleaned text.

## Latency targets

- [ ] Record 20 dictations on the default engine (Whisper) with the same LLM
      model as the baseline (`gpt-4.1-nano`): 10–30-word sentences in Notes,
      Slack, and a browser field. In About Voxline → Diagnostics, write down
      the medians for transcribe, total, and "First words", and compare them
      with the Targets table in
      `docs/superpowers/specs/2026-10-08-transcription-engine-design.md`
      (transcribe ≤ 300 ms, total ≤ 1,500 ms, first words within 1 s).
- [ ] The synthetic bake-off put Whisper's finish median near 730 ms, so expect
      to miss the transcribe target until the early-finish follow-up listed at
      the end of that spec lands. Record the number either way.

## Bake-off on real clips

- [ ] Follow `docs/bakeoff.md`: turn on `voxline.debug.saveBakeoffClips`,
      dictate at least 20 clips, correct each `.txt`, write `terms.txt`, and
      run the bake-off. Record the verdict. If it names an engine other than
      Whisper, flip the default in a follow-up change.
- [ ] Turn the flag off and delete the clips as that doc describes. After new
      dictations, `find ~/Library/Application\ Support/voxline -name '*.wav'`
      prints nothing.
