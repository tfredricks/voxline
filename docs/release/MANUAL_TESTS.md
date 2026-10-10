# Manual test pass: update check

Run this checklist after the release workflow succeeds and before announcing the release.

## Setup

You'll need two installed copies of voxline:
- The *previous* released version (the one users are currently on).
- A debug build pointed at a *staging* appcast you control, for the tamper test.

Configure a staging appcast by setting `SUFeedURL` in a debug build's `Info.plist` to a file URL or a private Pages branch.

## End-to-end happy path

- [ ] Launch the previous release. Confirm `Settings → General` shows "Automatically check for updates" enabled.
- [ ] Force a scheduled check: from the menu, click "Check for updates…".
- [ ] Sparkle's modal appears, says a new version is available, shows the release notes from the appcast.
- [ ] Click Install. Sparkle downloads from the GitHub Release URL, verifies the EdDSA signature, replaces the app, relaunches.
- [ ] The new version launches without a Gatekeeper warning. Confirm via `spctl -a -v /Applications/voxline.app` (expected: `accepted source=Notarized Developer ID`).
- [ ] Settings (the Updates toggle on General, hotkey, model, API keys) survived the swap.

## Gentle reminder UI

- [ ] With a known pending update on the staging feed, leave voxline running idle for >24h (or temporarily reduce `SUScheduledCheckInterval` to ~120s in a debug build from `scripts/build-local.sh --debug`; an Xcode ⌘R build has build number 1 and never starts the updater).
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

# Manual test pass: platform reset

Covers what automated tests cannot: real AX reads and
Sparkle running unsandboxed.

## Numbers

- [ ] Numbers: select a cell (not editing it), dictate. The text lands in the cell. Repeat in Excel.

## Fresh install

- [ ] `scripts/reset-local-state.sh`, launch, complete the wizard, dictate into Notes.

## Accessibility reads work

- [ ] Run a Debug build with `VOXLINE_TRACE_LLM=1` from Xcode. Dictate into the
      middle of an existing paragraph in Notes. The trace's `textBeforeCursor`
      and `textAfterCursor` are populated (not `(nil)`).
- [ ] Select text in Notes, hold the command chord, say
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

# Manual test pass: transcription engine

Covers what automated tests cannot: real speech engines, real audio hardware,
real full-screen Spaces, and real network failure. Use an Apple Silicon Mac and
a build from `scripts/build-local.sh`, with Anthropic or OpenAI cleanup
configured. Keep `scripts/tail-logs.sh --last 2m pipeline` open in a terminal;
several items below check it.

## Live text in the pill

- [ ] On the default engine (Apple Speech), and again on Whisper, hold the chord in Notes and speak 15–20
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
- [ ] Select text, hold the command chord, and speak a
      command with Wi-Fi off. The error appears without a Retry button.

## Microphone disconnected

- [ ] Settings → Dictation → Microphone: pick a USB mic, not the built-in one.
      Hold the chord, speak half a sentence, and unplug the mic while still
      holding. The pill says "Microphone disconnected — stopped recording" and
      what you said before the unplug is transcribed and inserted. Switch the
      input back and confirm the next dictation works.
- [ ] If that toast never appears, note the mic and macOS version in the test
      log instead of failing the pass: the interruption only fires when the
      audio engine actually stops, and some devices keep it running.

## Switching engines

- [ ] Settings → Dictation → Engine lists "Apple Speech —
      on-device, fastest", "Whisper — on-device", and "OpenAI — cloud, audio
      leaves your Mac". A fresh install has Apple Speech selected, and the
      Whisper model picker shows only while Whisper is selected. Upgrading
      from 0.3.1 also lands on Apple Speech.
- [ ] Select Apple Speech and dictate in Notes. Text lands. Select Whisper and
      dictate again. Text lands.
- [ ] Choose a Whisper model that is not downloaded yet (for example small.en
      if only large-v3 turbo is cached). The menu bar shows download progress,
      and dictation is unavailable until it finishes: the hotkey does nothing
      and "Retry last dictation" is disabled. After it finishes, dictate: text
      lands.
- [ ] Select OpenAI with no OpenAI key stored. A caption says audio is sent to
      OpenAI with your key, and a warning says no key is stored.
- [ ] With OpenAI selected and no key, the menu bar shows the missing-key
      error. Select Whisper (model cached): the error clears at once. Repeat
      with Apple Speech in place of Whisper.
- [ ] Turn Wi-Fi off, select a Whisper model that is not cached, and wait for
      "Model setup failed…". Select Apple Speech: the error clears.
- [ ] Add an OpenAI key (in Recognition when cleanup is not using OpenAI;
      otherwise in AI Provider) and dictate. Live text appears a phrase at a time
      and the final text is inserted.
- [ ] `scripts/tail-logs.sh --last 5m metrics` names the engine for each
      dictation above.
- [ ] Quit and relaunch: the selected engine is unchanged. Reset to Defaults
      selects Apple Speech.

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
- [ ] With Wi-Fi off and OpenAI selected, tap the chord quickly ten times.
      The pill goes away at once each time; it never sits on "Transcribing…".
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
- [ ] `scripts/reset-local-state.sh --keep-model --reset-tcc`, then launch.
      On Permissions, click Grant on Microphone and choose Don't Allow. The
      button now reads "Open System Settings" and opens Privacy & Security →
      Microphone. Turn voxline on there: the row turns green within 2 s and,
      with Accessibility granted, Continue enables. Turn it off again: Home's
      Microphone row offers the same button.
- [ ] While the wizard downloads the speech engine, and after its Retry, no
      separate "Preparing Voxline" window opens over it: the progress shows
      only in the "Speech engine" step.

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

## Keyboard layouts

- [ ] Add the "Dvorak – QWERTY ⌘" input source and switch to it. Dictate into
      Notes and into Terminal: the text is pasted (no ⌘I italics, nothing
      typed instead). Repeat with plain "Dvorak". Switch back afterwards.
- [ ] With "Dvorak – QWERTY ⌘" active, select text in an app whose selection
      Accessibility can't read (for example a Terminal tab) and run a
      command: the selection is copied and the edit lands.

## No regressions

- [ ] Select text in Notes, hold the command chord, say "make
      this shorter". The selection is replaced.
- [ ] With nothing editable focused, dictate. The pill shows "No text field
      focused — copied".
- [ ] Show history… lists these dictations with the raw transcript next to the
      cleaned text.
- [ ] Dictate, open Show history…, and close it. A few minutes later reopen
      it: the Time column says how long ago that is now, not "1 min. ago",
      and the window is where you left it. Left open, the times move on
      each minute.

## Latency targets

- [ ] Record 20 dictations on the default engine (Apple Speech) with the same LLM
      model as the baseline (`gpt-4.1-nano`): 10–30-word sentences in Notes,
      Slack, and a browser field. In About Voxline → Diagnostics, write down
      the medians for transcribe, total, and "First words", and compare them
      with the Targets table in
      `docs/superpowers/specs/2026-10-08-transcription-engine-design.md`
      (transcribe ≤ 300 ms, total ≤ 1,500 ms, first words within 1 s).
- [ ] On the synthetic bake-off Whisper finishes in about 475 ms (median) when
      you pause about half a second before releasing, and about 660 ms when
      you release mid-word, so the 300 ms transcribe target is still likely to
      be missed with Whisper. Record the number either way; Apple Speech
      finishes in about 120 ms if you want to compare.

## Bake-off on real clips

- [ ] Follow `docs/bakeoff.md`: turn on `voxline.debug.saveBakeoffClips`,
      dictate at least 20 clips, correct each `.txt`, write `terms.txt`, and
      run the bake-off. Record the verdict. If it names an engine other than
      Apple Speech, flip the default in a follow-up change.
- [ ] Turn the flag off and delete the clips as that doc describes. After new
      dictations, `find ~/Library/Application\ Support/voxline -name '*.wav'`
      prints nothing.

# Manual test pass: command mode

Covers what automated tests cannot: real Accessibility writes in third-party
apps, real key events and OS shortcuts, other apps reading the clipboard, and
Screen Sharing. Use an Apple Silicon Mac and a build from
`scripts/build-local.sh`, with Anthropic or OpenAI cleanup configured. Keep
`scripts/tail-logs.sh --last 2m metrics` open in a terminal: each insert logs
`strategy=` (`ax`, `paste`, `typing`, `copy`, `none`) and each command logs
`action=` (`replace_selection`, `insert`, `rewrite`). The default chords are
Left Shift + Left Control (dictation) and Left Shift + Left Option (command).

## Selection edits

- [ ] In Notes, Slack, VS Code, and Gmail in Safari, select a few sentences
      and say each of "make this a bullet list", "translate this to Spanish",
      and "summarize this". Each time the selection is replaced in place (not
      appended), and ⌘Z restores the original text in one step.
- [ ] `metrics` shows `strategy=ax` for Notes and `strategy=paste` for Slack,
      VS Code, and Safari (they are paste-first), with `action=replace_selection`.
      If an app lands on `copy` or `none`, note it.
- [ ] Copy a word you will recognize. Select a sentence and say "delete this"
      with the command chord in Notes, TextEdit, Slack, and Chrome (a text
      area on a web page). Each time the selection is deleted: `strategy=ax`
      in Notes and TextEdit, `strategy=typing` in Slack and Chrome (voxline
      presses the delete key). If Slack or Chrome shows "Couldn't delete in
      place — nothing was changed" instead, note it with the reason from
      `scripts/tail-logs.sh --debug --last 2m paste`: "no selection to
      delete" means the selection was readable only through ⌘C, and "isn't
      editable" means the field doesn't report its value as settable.
- [ ] In Terminal, type a few characters at the prompt without pressing
      Return, select some earlier output, and say "delete this". The toast
      reads "Couldn't delete in place — nothing was changed" and the prompt
      line is untouched. Repeat in iTerm2. After all of these, ⌘V pastes the
      word you copied: the clipboard never changed.
- [ ] Select text on a read-only Safari page, say "delete this": nothing is
      deleted, the page doesn't navigate, and the toast says nothing was
      changed.
- [ ] In Terminal, type a few characters at the prompt without pressing
      Return, select some earlier output, and say "summarize this"; then
      press ⌥1 on the same selection. Each time the toast reads "Couldn't
      edit in place — copied, ⌘V to apply", nothing is added at the prompt
      (the characters you typed are all that is there), and ⌘V pastes the
      result. Repeat in iTerm2. Then clear the prompt, select nothing, and
      say "write a command that lists the files here": it is pasted at the
      prompt, as a dictation would be. Then say "write a short script that
      makes a folder and lists it, one command per line": nothing runs, the
      toast reads "Several lines — copied, ⌘V to paste", and ⌘V pastes the
      lines.
- [ ] VS Code, nothing selected, cursor on a non-empty line: run a command that
      inserts text ("add a TODO comment"). The cursor's line is not replaced
      or deleted. The built-in untrusted-field list for VS Code and Cursor is
      provisional: if the field read there turns out to be the real document,
      note it in the test log so the list can be emptied.
- [ ] A selection of more than 8,000 characters (paste a long article into
      Notes and select all): the toast reads "Selection too long — 8,000
      characters max" and nothing changes.
- [ ] Press Esc while the pill reads "Editing…". The pill says "Cancelled" and
      nothing is inserted.

## Drafting at the cursor

- [ ] Open a message in Mail and start a reply with nothing selected. Hold the
      command chord and say "draft a short reply agreeing to the Thursday
      time". The reply is inserted at the cursor. `metrics` shows
      `action=insert` (Mail compose is web content, so `strategy=paste`), and
      ⌘Z removes it.
- [ ] In Notes, put the cursor at the end of a paragraph and say "continue
      this with one more sentence". The sentence is added after the cursor.

## Rewrite in place

- [ ] In Notes, type three paragraphs and bold one word in the first. With
      nothing selected and the cursor in the last paragraph, say "make the
      last paragraph shorter". Only the last paragraph changes, the bold word
      is still bold, `metrics` shows `action=rewrite`, and one ⌘Z restores the
      paragraph.
- [ ] Repeat in TextEdit (rich text).

## Supersets and shortcuts

Each of these leaves no text from voxline and no new History entry. The start
blip may play on the discarded ones.

- [ ] Hold the dictation chord, then add ⌘ within a second. Repeat holding ⌘
      first, then the chord keys.
- [ ] Settings → Dictation: set the dictation chord to Left Cmd + Left
      Shift. Press ⌘⇧4. The screenshot crosshair appears (Esc to dismiss) and
      no recording starts. Restore the chord.
- [ ] In Safari with several tabs open, press ⌃⇧Tab with the default
      dictation chord. The tab switches and no recording starts.
- [ ] In Notes, type ⇧⌥- (an em dash) with the default command chord. The
      dash is typed. A recording may start and is discarded (you hear the
      start sound and see the microphone indicator); nothing else is typed.
- [ ] Type a paragraph with capital letters for 20 seconds. The system mic
      indicator never appears (Shift alone no longer starts the microphone).
- [ ] Hold Left Shift + Left Control, and within a second add Left Option. The
      recording is silently discarded. Release all keys: a normal dictation
      then works.
- [ ] In Notes, dictate a long sentence. While the pill still shows it
      processing, hold ⇧⌥ (the default command chord) and tap → to extend a
      selection, and keep holding until the text lands. No recording starts
      (no start sound, no microphone indicator), and → still extends the
      selection after a pause of more than a second. Repeat pressing ⌥1
      while it processes and holding ⌥ until the text lands: the microphone
      indicator never appears.

## Preset shortcuts

- [ ] Settings → Commands lists ⌥1 Fix grammar, ⌥2 Make concise, and ⌥3 Make
      professional, with the caption about ¡ ™ £. The recorder warns that ⌥2
      types “™” on your keyboard.
- [ ] Select a paragraph in Notes and press ⌥2. Nothing records (no waveform,
      no blip). The pill shows "Make concise…", the paragraph is replaced, and
      ⌘Z restores it. `metrics` records it as a preset with `strategy=ax`.
- [ ] Press ⌥2 with nothing selected. The toast reads "Select text to
      transform" and no ™ is typed.
- [ ] Press ⌥1 and ⌥3 on selections in Notes and Slack. Each works.
- [ ] Select a long paragraph in Notes and press ⌥1; while the pill shows
      "Fix grammar…", press ⇧⌥→. The preset still lands, with no "Cancelled".
- [ ] Open Settings → Commands, focus a text field, and press ⌥2.
      It types ™ (presets are off while voxline is frontmost).
- [ ] Select a paragraph in Notes and hold ⌥2 down for two seconds. Make
      concise runs once: key repeat neither runs it again nor types ™.
- [ ] Add a preset, record a shortcut for it, and leave its instruction
      empty. The row warns "This preset has no instruction, so its shortcut
      does nothing.", and the shortcut types its usual character in Notes.
- [ ] Remap Make concise to another shortcut (for example ⌃⌥C). It works at
      once without relaunching, and ⌥2 types ™ again in other apps.
- [ ] In the shortcut recorder, try Esc, a combo with only ⇧, a combo already
      used by another preset, and ⇧⌥ with any key (“⇧⌥ is your command
      hotkey”). Each is rejected with a message.
- [ ] Add a preset, edit its instruction, remove it, then "Restore default
      presets". Quit and relaunch: the table is unchanged. Reset to Defaults
      on the General page leaves the presets alone.
- [ ] While a preset's shortcut recorder is open, hold the dictation chord. No
      dictation starts.
- [ ] In a password field, ⌥2 types ™ (Secure Event Input hides the key from
      voxline) and nothing is sent to the LLM provider.

## Command model

- [ ] Settings → Commands → Command model is empty with the provider's default model as its
      placeholder. Run a command: it works.
- [ ] Enter a larger model id from the same provider and run a command: it
      works, with a slower response. Enter an invalid id: the pill shows the
      provider's error followed by "Nothing was changed." Clear the field.
- [ ] Type a model id, then change the provider in Settings → AI Provider. The
      Command model field is empty again.
- [ ] Reset to Defaults clears the Command model.

## Dictation regression on the AX-first path

Dictate a sentence into each app, with some text already in the field.
Each time the text lands exactly once, in the right place, with no spurious
"Couldn't insert — copied". In the native apps ⌘Z undoes it in one step.
Write down the `strategy=` shown for each; any app that misbehaves on `ax`
joins the paste-first list before release.

- [ ] Notes
- [ ] TextEdit
- [ ] Pages
- [ ] Word
- [ ] Mail (reply body)
- [ ] Messages
- [ ] Xcode (a source file)
- [ ] A Numbers cell
- [ ] An Excel cell
- [ ] Terminal
- [ ] Slack
- [ ] Safari (a web form field)
- [ ] Other Chromium or Electron apps (Chrome, Discord, Obsidian): no spurious
      "Couldn't insert — copied".
- [ ] Alacritty, kitty, or WezTerm, if installed: the dictation is pasted.
- [ ] A VM or remote-desktop window with a text cursor: the dictation is
      pasted, as before command mode.
- [ ] Quit voxline, run
      `defaults write ~/Library/Preferences/com.voxline.app voxline.insert.axFirst -bool NO`,
      relaunch, and dictate in Notes: `strategy=paste`. Quit, delete the key
      (`defaults delete …`), and relaunch to restore `ax`.
- [ ] Quit voxline, run
      `defaults write ~/Library/Preferences/com.voxline.app voxline.insert.pasteFirstExtra -array com.apple.Notes`,
      relaunch, and dictate in Notes: `strategy=paste`. Quit, delete the key,
      and relaunch.

## Clipboard

- [ ] Copy an image, then dictate into a busy Slack (a channel with many
      messages and tabs open). The dictation lands, and then pasting into
      Preview's File → New from Clipboard gives back the image.
- [ ] Dictate into Notes, then copy other text within 1 s of the insert. The
      new text is still on the clipboard a few seconds later.
- [ ] Run Maccy, Paste, or another clipboard manager that reads the clipboard
      eagerly, copy some text, then dictate into Slack. The dictation lands
      and the original text is back on the clipboard afterwards.
- [ ] Copy rich text (bold in Pages), dictate into Slack, then paste into
      Pages. The paste is still rich.

## Issues 10, 12, 20, and 22

- [ ] Issue 10: open Settings → Dictation, start recording a new
      dictation chord, and press and hold the old chord keys. No dictation
      starts, no pill appears, and nothing is pasted into the Settings page.
      Start recording a chord again, then switch to another app or close the
      main window. The recorder stops, and dictating in Notes works.
- [ ] Issue 12: hold the chord and speak. While still holding, turn voxline off
      in System Settings → Privacy & Security → Accessibility. The recording
      stops instead of sticking: the stop sound plays, the microphone
      indicator goes off, the pill moves on from "Recording", and the menu bar
      keeps the Accessibility error, with no relaunch. Turn Accessibility back
      on: Esc reaches your apps again and the next dictation works. Repeat
      with "Pause Voxline" from the menu bar instead of revoking
      Accessibility: the dictation finishes and lands.
- [ ] Issue 20: hold the chord, keep talking, and open the menu-bar menu. Leave
      it open until the pill reads "Stopped at 5 minutes", then close it. The
      text lands.
- [ ] Issue 22: connect to a second Mac running voxline with Screen Sharing and
      control it from the first. Dictate into Notes on the remote Mac with the
      dictation chord, then select text and use the command chord. Both work.

## Hotkey fallback and other edge cases

- [ ] Accessibility granted and Input Monitoring denied (System Settings →
      Privacy & Security → Input Monitoring, off or removed for voxline):
      the hotkey still starts a dictation.
- [ ] Select OpenAI as the speech engine with no OpenAI key stored and dictate:
      an error appears. Switch to Apple Speech or Whisper: the error clears
      and a dictation works.
- [ ] Select text in an app that needs the ⌘C fallback (the selection read
      comes back inconclusive, as in some Electron apps), start a command,
      and press Esc right after releasing the chord. The pill says
      "Cancelled", nothing is inserted, and the previous clipboard is intact.
- [ ] Hold the command chord, speak, and while still holding, click "Play
      sound on record start/stop" in Settings → General (an ⇧⌥-click). The
      recording is not interrupted: the pill keeps recording until you
      release. Then hold Left Shift alone, click the toggle back (a
      shift-click), and add Left Control: a dictation starts.
- [ ] Open Settings → Commands, hold the command chord, speak, then turn
      command mode off while still holding (click the Command mode toggle):
      nothing is sent and no command runs. The recording finishes at once
      (stop sound) with no toast, the clipboard is
      unchanged, releasing the keys starts nothing, and
      `scripts/tail-logs.sh --debug --last 2m pipeline llm` shows "command
      mode was turned off while recording; discarded" and no POST. Turn
      Command mode back on.
- [ ] With the default presets, choose Pause Voxline from the menu bar. In
      Notes, ⌥2 on a selection types ™ and nothing runs. Choose Resume
      Voxline: ⌥2 on a selection runs Make concise again, and Esc while it
      runs cancels it ("Cancelled").
- [ ] Over Screen Sharing (as in issue 22), open Settings on the remote Mac
      and, from the controlling Mac's keyboard, record a new dictation chord
      and a new preset shortcut. Both recorders register the keys you
      pressed, and both work afterwards. Put both back afterwards.

## Safety

- [ ] Click into a password field in Safari, hold the command chord, and speak.
      The toast reads "Command mode is off in password fields" and nothing is
      sent.
- [ ] Dictate into a password field. Nothing is inserted into it, and the
      pill reports why.
- [ ] Select text in Notes, then from Terminal run
      `sleep 3; kill -STOP $(pgrep -x Notes)` and click back into Notes during
      the 3 s. Hold the command chord, speak, release. voxline must not
      beachball for more than a few seconds, and shows "The app isn't
      responding — try again" (or, if the read finished before the freeze,
      copies the result: "Couldn't edit in place — copied, ⌘V to apply").
      Run `kill -CONT $(pgrep -x Notes)`: the text appears in Notes at most
      once, never twice. Repeat with a preset shortcut, with dictation
      (expect "Field isn't responding — copied"), and with Slack as in the
      platform reset pass.
- [ ] Freeze an app at insert time: click into Slack's message box, run
      `sleep 6; kill -STOP $(pgrep -x Slack)` in Terminal, click back into
      Slack, and hold the dictation chord, speaking, until the 6 s are up;
      then release. voxline beachballs for at most about 2 s, then copies
      with a toast, and `scripts/tail-logs.sh --debug --last 2m context`
      shows the insert's focused-element read failing once ("focused
      element: read failed (cannotComplete)"), not a run of slow reads. Run
      `kill -CONT $(pgrep -x Slack)`.
- [ ] In a busy Electron app (Slack or Discord while a large workspace
      loads) and in an app that exposes no focused element to Accessibility
      (Alacritty, kitty, or a VM or remote-desktop window), dictate, then
      select text and run a command ("make this formal"). Each lands, or is
      copied with a toast; nothing hangs or fails silently.

## Latency targets

- [ ] Record 20 runs of each row of the Targets table in
      `docs/superpowers/specs/2026-10-08-command-mode-v2-design.md`, with the
      default models, and compare the medians (About Voxline → Diagnostics
      and `metrics`): dictation `insertMs` in Notes and TextEdit (≤ 120 ms,
      baseline 370 ms via paste); dictation `totalMs` in all apps (no more
      than 5% above the transcription-engine median); command `totalMs` for
      `replace_selection` on under 1,000 characters (≤ 2,500 ms); preset
      `totalMs` on the same selection size (≤ 1,800 ms). Record the numbers
      even where a target is missed.

## Meetings

Setup: `defaults write ~/Library/Preferences/com.voxline.app voxline.debug.meetingCapSeconds -int 120` shortens the cap to 2 minutes (warning at 1:00). Delete it afterwards.

- [ ] Run `TEST_RUNNER_VOXLINE_SYSTEM_TAP_SMOKE=1 xcodebuild test … -only-testing:voxlineTests/SystemAudioTapSmokeTests` once (first run shows the System Audio Recording prompt; allow, rerun).
- [ ] First Start Meeting Recording shows the consent alert once; Cancel records nothing.
- [ ] First recording shows macOS's System Audio Recording prompt. **Allow** → a Zoom/Meet/Teams call with 2+ remote speakers produces Me + Speaker 1…N, and action items name the right labels.
- [ ] **Deny** (or revoke in System Settings → Privacy & Security → Screen & System Audio Recording) → notes are processed as in-person and carry the "No sound from your Mac was captured" note.
- [ ] In-person meeting (no call) produces Speaker 1…N from the mic.
- [ ] Trigger a Slack/Mail notification sound during an in-person meeting; speakers are still Speaker 1…N (no "Me").
- [ ] Allow the System Audio Recording prompt mid-recording; verify audio arrives without a restart.
- [ ] Call on speakers vs. headphones: on speakers, remote speech does not also appear as "Me" (echo suppression); note any leaks.
- [ ] Headset with a mic (AirPods or USB) as the default output: system track contains the call audio, not your mic; note whether AirPods switch to the low-quality call profile when recording starts.
- [ ] Tap with no sound playing for 10 s, then play audio: recording continues, transcript timestamps line up between Me and call speakers.
- [ ] Warning notification at the cap minus the lead; automatic stop at the cap; notes still written.
- [ ] Unplug headphones / switch input device mid-meeting: recording continues; transcript has a gap at most.
- [ ] Quit during recording → confirmation; relaunch → "Process unfinished meeting…?" → Process writes notes for the recorded part.
- [ ] Log out (and separately Restart, Shut Down) during recording and during processing → no confirmation, the Mac doesn't say Voxline interrupted it, and it goes through; log back in / start up → "Process unfinished meeting…?" offers the meeting.
- [ ] `kill -9` voxline mid-recording → relaunch → recovery works the same.
- [ ] Start a meeting, talk for a minute, then close the lid (or Apple menu → Sleep) for a few minutes. On wake a "Meeting recording stopped — Your Mac went to sleep" notification has appeared, the notes cover the minute before sleep, and the meeting's duration doesn't include the sleep.
- [ ] Hold the dictation hotkey during a meeting: dictation works as usual.
- [ ] No API key: file has the transcript and "Notes not generated…"; add a key; Regenerate Notes writes a "(regenerated)" file.
- [ ] Offline, with no Whisper model downloaded, record two short meetings: each fails with a notification. Quit and relaunch → the menu still has Retry Processing, and both Home rows show Failed with Retry. Go online; the menu item retries the newer meeting, and each Home row's Retry retries its own.
- [ ] Offline first run with no SpeakerKit model: notes say speakers couldn't be separated; call audio labeled "Them".
- [ ] Settings → Meetings: folder picker, shortcut (rejects a preset's combo and the dictation chord), notes model placeholder, retention, timer toggle.
- [ ] Settings → Meetings: record ⌘M as the shortcut → it is kept, and an orange "common app shortcut" warning stays under the recorder. Record ⌃⌥M, then change the dictation chord to Left Control + Left Option → back on Meetings, the warning says ⌃⌥ is your dictation hotkey.
- [ ] Meeting shortcut starts and stops a recording from any app.
- [ ] Press the meeting shortcut while the last meeting is still processing → a "Meeting recording didn't start" notification; nothing records, and the processing finishes as usual.
- [ ] Retention "Don't keep": no `.pcm`/`.m4a` remain in `~/Library/Application Support/voxline/meetings/<id>/` after notes are written.
- [ ] One-hour real meeting: note the time from Stop to "Meeting notes ready" (spike target ≤ 4 min on synthetic audio with small.en; record the real number).
- [ ] Live transcript: Start a meeting; the chip has a chevron. Expand: "Listening…", then your own words appear under "Me" within a few seconds, bright once settled, dim while changing.
- [ ] Live transcript on a call with headphones: the other side appears under "Them"; turns interleave in speaking order.
- [ ] Live transcript in-person (system tap denied or silent): lines carry no label.
- [ ] Collapse and expand: the top-left corner stays put; with the chip near the bottom of the screen the expanded panel stays on screen.
- [ ] Expanded state and position survive Stop and the next Start.
- [ ] Drag the panel by the time; the chevron toggles without moving it.
- [ ] With Zoom, Slack, or another app frontmost (voxline not active), the first click on the chevron toggles the panel; if the first click does nothing and only the second toggles, note it (fix: an `NSHostingView` subclass returning true from `acceptsFirstMouse(for:)`).
- [ ] Expanding and collapsing resizes the panel in one step with no flash of the old size.
- [ ] Hold the dictation hotkey mid-meeting: dictation works; the words show under "Me".
- [ ] Unplug headphones mid-meeting: "Me" keeps updating after the restart.
- [ ] Stop: the panel disappears; the notes after processing match a meeting recorded with Live transcript off.
- [ ] Settings → Meetings → Live transcript off: the chip is exactly the old chip and `scripts/tail-logs.sh meetings` shows no "live transcript" line. Timer off disables the toggle.
- [ ] Full-screen Zoom or Teams: the expanded panel stays visible over it.
- [ ] One-hour meeting with the panel expanded: lines still arrive in the last minute; note voxline's CPU in Activity Monitor in the spec's results table.

## Learning

Watch `scripts/tail-logs.sh learning` throughout: every line carries counts and reasons only, never text.

- [ ] **Word, Cocoa.** In TextEdit, dictate "ask Cooper Nettis to review". Change it to "Kubernetes" in the field and wait 30 s. "Learned: Kubernetes" appears with Undo, and Settings → Vocabulary lists it as Learned. Dictate the sentence again: it comes out right.
- [ ] **Fix then send.** In Messages, dictate "ask Cooper Nettis", fix it to "Kubernetes", wait 3 s, and press Return. "Learned: Kubernetes" appears (log: `source=lastGood`). After sending, type a follow-up message in the same input within 30 s: Kubernetes is still learned (log: `end=regionGone`) and the follow-up is not recorded. Repeat in a Mail compose: fix, then click Send.
- [ ] **Half-typed or half-deleted.** In Messages, dictate "use lang graph for this", select "lang graph", type "LangGraph", and press Return right after the last key: nothing partial such as "LangGr" is learned. Dictate "use Argmax", hold Backspace until the input is empty, wait 30 s: nothing is learned (log: `region=discarded`).
- [ ] **Fix then dictate at once.** As in the first check, but start the next dictation within 5 s of the fix. The toast appears after that dictation inserts, and that dictation already has the word right.
- [ ] **Undo.** Click Undo on the toast. The word leaves the list. Make the same fix again: nothing is learned.
- [ ] **Not vocabulary.** Change "Tuesday" to "Thursday", "there" to "their", and the case of a word: nothing is learned.
- [ ] **Focus leaves.** Dictate in Notes, click into another app, and edit nothing: the log shows `end=focusLeft region=unchanged`.
- [ ] **Electron and web.** Dictate and fix a word in Slack, then in Gmail in Safari. Learning either works or logs `valueUnreadable`. No wrong toast, no slowdown. Record which apps learn.
- [ ] **Skipped fields.** Terminal, VS Code, and a password field log a skip and never toast.
- [ ] **Style.** After 20 Slack dictations, Settings → Vocabulary → Chat shows a sensible note. With `VOXLINE_TRACE_LLM=1`, the next Slack dictation's system prompt carries the note and at most two quoted Slack examples, and its output follows the note.
- [ ] **Edited note.** Edit the Chat note. After 20 more Slack dictations it is unchanged and says "Edited by you". Regenerate asks, then replaces it.
- [ ] **Both off.** Turn both toggles off. A traced dictation's system prompt has no "Learned style" or "Examples" block, `log stream` shows no `learning` lines, and a fix in the field learns nothing.
- [ ] **Issue 15.** Reset to Defaults leaves Custom vocabulary and Learning alone. Clear All asks before removing anything.
- [ ] **Reset Learning.** It asks, then empties the notes and removes only the learned words; words added by hand stay.
- [ ] **Latency.** 20 Slack dictations with both toggles off, then 20 with both on: the Diagnostics `totalMs` median is within 5%.

## Main window and Dock icon

Show Voxline in Dock is off unless a step says otherwise.

- [ ] Open voxline from Finder → Home opens and the Dock icon shows. Close the window → the Dock icon goes away.
- [ ] Start a meeting, choose Quit Voxline, then Cancel in the confirmation → no Dock icon is left behind. Repeat with each meeting alert (consent, silent system audio, cap warning).
- [ ] Settings → Meetings → choose the notes folder, then Cancel the picker → after closing the main window, no Dock icon is left.
- [ ] With no window open, open voxline from Spotlight → Home opens.
- [ ] Minimize the main window → the Dock icon and the minimized tile stay. Restore it from the Dock.
- [ ] Put Safari in full screen, then menu bar → Open Voxline → the window appears over the full-screen Space.
- [ ] Turn Show Voxline in Dock on → close the window → the Dock icon stays. Click it → Home opens. Turn it off with no window open → the icon goes.
- [ ] Open Settings → AI Provider, switch to another app, click the Dock icon → the window comes forward still on AI Provider.
- [ ] First run: from the wizard's permissions step open System Settings, then click voxline's Dock icon → the wizard comes forward and no main window opens. Do the same with menu bar → Open Voxline, menu bar → Settings…, and ⌘, → each brings the wizard forward instead.
- [ ] Launch at login on, log out and back in → no window and no Dock icon. The menu bar works.
- [ ] Revoke Accessibility while running → Home opens with Accessibility missing. Re-grant → it turns green within about a second.
- [ ] Quit, turn Accessibility off for voxline (Input Monitoring on), and launch → once the model is ready, the menu-bar icon shows the warning triangle, the menu has "Fix permissions…", and Home's status says Accessibility is required (never "Ready", never "revoked"). Grant it → "Ready" within about a second and the hotkey works. Repeat by pausing voxline, turning Accessibility off, and resuming → the same warning.
- [ ] Home's recent meetings: click a finished meeting → its notes open. "Open meetings folder" → Finder opens the notes folder. With no notes written yet (the folder doesn't exist), the button creates it and Finder opens it, empty.
- [ ] Open Settings → Dictation, close the window → the mic indicator turns off immediately; dictate once with the window closed → it stays on for about 90 seconds after the dictation, then turns off without another dictation.
- [ ] Dictate once, then within 90 seconds press the chord and speak immediately as you press → the first word lands. Hold Left Control alone for a moment → the mic indicator comes on at once (or stays on inside the 90 seconds); release it → it turns off (or stays on until the 90 seconds end). Hold Left Shift alone and type a capital letter → the indicator never comes on. The start sound plays after the pill appears, never before.
- [ ] Edit a preset instruction, a style note, the command model (Commands), and the meeting notes model (Meetings); close the window with the last field focused, reopen → all four edits kept.
- [ ] Reopen the window → Settings → General shows current Launch at Login approval state.

### Settings pages

- [ ] Each page fits at 720×480 and at full screen, with the scroll bar at the window edge.
- [ ] Scrolling over a style note on Vocabulary scrolls the page.
- [ ] In a style note, Return ends editing and ⌥Return inserts a line break.
- [ ] The mic-in-use indicator is on only on Dictation.
- [ ] The mic indicator goes off when the main window is in the background on Dictation: leave it on Dictation, then minimise it, hide voxline with ⌘H, and click into another app → the indicator turns off each time. Bring the window back to the front → the live level and the indicator come back.
- [ ] An API key typed and left by switching pages shows as Saved on return.
- [ ] Menu bar → Settings… opens General; with the main window already open on Home, ⌘, switches it to General.
- [ ] Removing the API key shows an orange mark on AI Provider and a Setup row on Home, whose button opens AI Provider.
- [ ] After re-saving the key, the AI Provider mark and the Home Setup row clear.
- [ ] Reset to Defaults… asks before resetting.
