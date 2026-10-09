# Changelog

All notable changes to voxline are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
once it reaches its first tagged release.

## [Unreleased]

Everything since 0.3.1, the last published release. The big changes are a
choice of speech engine with live text while you speak, command mode that
edits text in place, preset shortcuts, meeting recording and notes, and an
app that is no longer sandboxed.

### Added

- **Choice of speech engine.** Settings → General → Recognition has an Engine
  picker: Apple Speech (on-device, fastest, now the default), Whisper
  (on-device), or OpenAI (cloud). Apple Speech won the bake-off on real
  recordings, so if you never picked an engine, voxline switches to it; your
  Whisper model stays downloaded, and you can pick Whisper again in Settings. Switching prepares the new engine in the
  background; if it needs a download, the menu bar shows progress and
  dictation is unavailable until it finishes. The Whisper model picker shows
  only while Whisper is selected.
- **Live transcript in the pill.** The words you say appear as you speak:
  settled text bright, text that may still change dim. After you let go, the
  pill reads "Transcribing…", "Cleaning up…", or "Inserting…", and past a
  minute of recording it shows the elapsed time.
- **Esc cancels a dictation** while it is recording, transcribing, or being
  cleaned up. The pill says "Cancelled" and the raw transcript, if there is
  one, goes to History. Esc is swallowed only while voxline is busy and is
  ignored once text is being inserted; the rest of the time it reaches your
  app as usual.
- **Retry.** When a dictation fails after transcription, the pill shows a
  Retry button for 8 seconds, and the menu bar has "Retry last dictation".
  Both re-run cleanup on the last raw transcript and insert the result into
  the focused field.
- **OpenAI cloud transcription (opt-in).** Pick "OpenAI — cloud, audio leaves
  your Mac" to transcribe with gpt-4o-transcribe through OpenAI's Realtime
  API, using your own OpenAI key. If the cloud fails mid-dictation, voxline
  transcribes the audio again on-device and shows "Cloud transcription
  failed — used on-device".
- **Engine bake-off tooling.** An opt-in test suite scores the engines on
  your own recordings and applies a fixed decision rule to pick the default
  (see `docs/bakeoff.md`). A hidden developer flag,
  `voxline.debug.saveBakeoffClips`, saves your dictations' audio and text as
  clips for it; it is off by default and is the only thing in voxline that
  writes audio to disk. `scripts/make-synthetic-bakeoff.sh` renders
  text-to-speech clips for smoke runs.
- About Voxline → Diagnostics shows "First words", the median time to the
  first live text.
- A hidden, experimental flag, `voxline.llm.skipShortUtterances`, skips AI
  cleanup for dictations of six words or fewer with no filler words. Off by
  default; there is no setting for it.
- **Command mode has its own chord** (Left Shift + Left Option by default).
  Hold it, say what to do, and let go. With text selected, the selection is
  replaced: rewrite, shorten, translate, reformat, or delete it. With nothing
  selected, the result is inserted at the cursor (draft a reply, continue,
  answer a question), or, for an instruction about existing text ("make the
  last paragraph shorter"), only the part of the field that changed is
  replaced. The model sees up to 12,000 characters of the field around the
  cursor, so replies and continuations follow what is already there. Selections
  over 8,000 characters are refused, and password fields are never read.
  In a terminal, selected output is never edited in place: the result is
  copied for you to paste with ⌘V, and only a one-line draft with nothing
  selected goes straight to the prompt; a draft of several lines is copied,
  so a shell can't run it line by line.
  With ⇧⌥ as the command chord, typing a ⇧⌥ character such as an em dash
  briefly starts and discards a recording (you hear the start sound and see
  the microphone indicator), and a slowly pressed ⌥-digit preset can light the
  microphone indicator for a moment.
- **Preset edit shortcuts.** Select text anywhere and press ⌥1 (Fix grammar),
  ⌥2 (Make concise), or ⌥3 (Make professional) to run a stored instruction
  with no recording. Settings → Command has an editable table: record any
  shortcut that includes ⌘, ⌥, or ⌃, rename a preset, rewrite its instruction,
  add or remove rows, or restore the defaults.
- **Command model.** Settings → Command → Command model picks a separate
  model for commands. Leave it empty to use the cleanup model; it is cleared
  when you change provider.
- Command and preset runs get their own median lines in About Voxline →
  Diagnostics, and the metrics log line records how each insert landed
  (`strategy=`) and what the edit did (`action=`).
- Per-dictation timing in About Voxline → Diagnostics: transcribe, cleanup,
  insert, and total, with medians over the last 50.
- History keeps the raw transcript next to the cleaned text.
- **Meeting recording and notes.** Up to 60 minutes of mic + system audio,
  on-device transcription (WhisperKit) and speaker separation (SpeakerKit),
  and LLM notes written as Markdown to a folder you choose. Start and stop
  from the menu or a shortcut; recovery after a quit or crash; Regenerate
  Notes; an audio retention setting.

### Changed

- **Whisper finishes sooner when you pause before letting go.** It keeps
  transcribing while you talk; if nothing but silence follows its last pass,
  it uses that result instead of transcribing the clip again (median finish
  731 ms → 475 ms on the synthetic bake-off with a half-second pause). Soft
  final words still get a full pass: silence is judged against how loud you
  have been speaking.
- **The recording pill sits at the bottom center** of the screen the mouse is
  on, instead of following the text cursor, and grows to fit the live
  transcript.
- **The recording limit is now 5 minutes** (was 60 seconds). When it hits,
  the dictation is inserted and the pill says "Stopped at 5 minutes".
- Diagnostics medians now cover dictations only, so command-mode runs no
  longer skew them, and "transcribe" is measured from release to final
  text. The metrics log line gains `firstPartial` and `skipCleanup`.
- The first-run wizard's model-download step is now "Speech engine", and is
  skipped when the selected engine is already ready.
- Cleanup requests are leaner: the output limit scales with the length of
  the dictation, empty context and vocabulary sections are no longer sent,
  and Claude 5-family models that think by default are asked for low effort.
- Reset to Defaults also resets the speech engine.
- **Dictation inserts through Accessibility where the app supports it**, so
  ⌘Z undoes it as one step in native apps. Electron and Chromium apps,
  browsers, terminals, and any web content still get a paste, and apps with
  no accessible focus (some terminals, VMs, remote desktops) get a plain
  paste as before. A hidden default, `voxline.insert.axFirst` set to NO,
  restores the paste-first behavior of earlier versions; `voxline.insert.pasteFirstExtra`
  (an array of bundle IDs) adds paste-first apps. Neither has a setting.
- **The command modifier picker is replaced by a second chord.** Settings →
  General → Hotkey now has a Dictation recorder and a Command mode toggle with
  its own recorder. On upgrade your old setting carries over: a modifier you
  had chosen becomes the command chord's second key, beside the dictation
  chord's first key. "Off", or a modifier that is already one of your
  dictation keys, gives the default Left Shift + Left Option, or turns
  command mode off if that is your dictation chord.
- **A chord held with another key no longer starts a recording.** Pressing
  Cmd+Shift+4 or Ctrl+Shift+Tab when a hotkey uses those modifiers does
  nothing; if a key or an extra modifier arrives in the first second of a
  recording, it is silently discarded. Holding Shift alone no longer turns on
  the microphone. If macOS withholds key events from the hotkey listener
  (Input Monitoring denied), it falls back to watching modifier keys only.
- **voxline is no longer sandboxed.** The App Sandbox blocked reading the
  focused field through Accessibility, which forced clipboard tricks for
  selection reads and left cursor context empty. The app now ships with the
  hardened runtime only. On first launch it copies settings, history, and
  vocabulary into the new preferences domain and moves custom modes and the
  cached Whisper model out of the old container, so nothing re-downloads.
- **Minimum macOS is now 26.** Older systems stay on 0.3.1.
- Dictating with no editable field focused now says so and copies the text
  to the clipboard instead of reporting success.
- Command mode reads the selection through Accessibility; the synthetic
  copy is now only a fallback for apps that expose no selection.

### Removed

- The post-dictation Shorter / Longer / Clearer pill. The pill now disappears
  as soon as text lands. Edit-by-voice stays available through command mode;
  keyboard presets for common edits arrive with the command-mode rewrite.

### Fixed

- A quick tap on the hotkey no longer shows a false "No audio captured"
  (issue 4).
- The recording pill is no longer pushed off-screen near the bottom or edge
  of the display, and now appears over full-screen apps (issue 7).
- Unplugging or losing the mic mid-dictation now finishes what was captured
  and says "Microphone disconnected — stopped recording", instead of
  silently dropping the rest (issue 8).
- OpenAI models that spend their output budget on hidden reasoning no longer
  paste nothing: truncated or empty responses are reported as errors, the raw
  transcript is copied to the clipboard, and Retry is offered (issue 14).
- An Anthropic refusal or truncated response now says so, instead of "Could
  not parse provider response" (issue 18).
- The first-run wizard is no longer a dead end offline: a failed download now
  offers "Quit Voxline" (issue 21).
- The last syllable of a dictation is no longer clipped when you release the
  hotkey (issue 23).
- Slow apps no longer paste your old clipboard instead of the dictation. The
  text is handed over as the app asks for it, and your clipboard is restored
  right after, or after 1.5 seconds, and only if nothing else was copied in
  the meantime (issue 6).
- Re-recording a hotkey in Settings no longer starts a dictation, and the
  recorder stops if you leave the Settings window (issue 10).
- A hotkey built from common modifiers no longer fires on every OS shortcut
  that includes them, such as a screenshot (issue 11).
- Losing Accessibility, or pausing voxline, while you hold the hotkey now
  finishes the recording, instead of leaving the microphone on and dictation
  stuck until you relaunch (issue 12).
- The typing fallback no longer splits an emoji in two (issue 16).
- The restored clipboard keeps its types in their original order, so rich
  text stays rich (issue 17).
- The recording time limit and permission checks no longer stall while the
  menu-bar menu is open (issue 20).
- The hotkey works over Screen Sharing and other remote or synthetic input
  (issue 22).
- voxline's own ⌘C and ⌘V keystrokes no longer turn into other shortcuts on
  layouts that switch to QWERTY while ⌘ is held, such as "Dvorak – QWERTY ⌘".
- The microphone permission prompt and the About window no longer claim that
  audio never leaves your Mac: they say it stays on your Mac unless you choose
  the OpenAI cloud engine.
- An OpenAI API key that can't be read from the keychain is reported as a
  keychain error, not as a missing key.
- Per-app modes saved by an older version load again. A modes file written
  before mode categories existed failed to load, and voxline silently used the
  built-in modes instead.
- Brief status messages in the pill now all appear and clear the same way
  (issue 26).
- Command mode no longer copies the whole line in editors such as VS Code
  when the app reports an empty selection, and a password field that does not
  answer is refused instead of being treated as safe to paste into.
- An edit that an app applies late is no longer inserted a second time; if it
  never shows up, the text is copied instead.
- A hung target app can no longer stall voxline: every Accessibility request
  times out after half a second.
- A keychain read failure no longer looks like "no key configured", and the
  setup wizard can no longer delete saved keys over a transient read error.

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
