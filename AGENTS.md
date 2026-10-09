# AGENTS.md

Guidance for coding agents working in this repo. Human contributors should read [CONTRIBUTING.md](CONTRIBUTING.md) and [README.md](README.md) instead.

## What this is

voxline is a native macOS menu-bar app (SwiftUI + AppKit, Swift Package Manager dependencies, no CocoaPods/Carthage). Hold a hotkey, speak, and it inserts cleaned-up text into the focused field:

1. `Audio/` captures mic input while the hotkey is held.
2. `Transcription/` turns the audio into text with the selected engine: Apple Speech (the default), Whisper on-device via [WhisperKit](https://github.com/argmaxinc/WhisperKit) (SPM dep: `argmaxinc/argmax-oss-swift`), or OpenAI Realtime (cloud, opt-in).
3. `Context/` assembles a context block (per-app mode prompt, focused-field AX info, custom vocabulary).
4. `LLM/` sends the transcript + context to Anthropic or OpenAI for cleanup (`AnthropicClient.swift` / `OpenAIClient.swift` behind `LLMService.swift`).
5. `Output/` inserts the result through Accessibility, or pastes and restores the clipboard.

`Pipeline/CapturePipeline.swift` orchestrates the above end to end (the command and preset paths live in `Pipeline/CapturePipeline+Command.swift`); `AppState.swift` and `Hotkey/HotkeyStateMachine.swift` drive the hold-to-talk state.

The second (command) chord runs the same capture, but the transcript is an instruction: `Context/EditContextReader` reads the selection and the field around the cursor, `LLM/` returns one edit (replace the selection, insert, or rewrite), and `Output/` applies it in place. Preset shortcuts skip the audio and run a stored instruction on the selection.

## Directory map

- `voxline/Audio`, `Context`, `Diagnostics`, `Hotkey`, `Learning`, `LLM`, `Meetings`, `MenuBar`, `Modes`, `Output`, `Permissions`, `Pipeline`, `Settings`, `Storage`, `Transcription`, `UI`, `Updates`, `Util`, `Wizard` — app source, one folder per concern.
- `voxline/Meetings/` — meeting recording (mic + Core Audio process tap) and post-stop processing (`MeetingPipeline`: WhisperKit, SpeakerKit, LLM notes, Markdown). Separate from the dictation pipeline. The live transcript in the timer chip (`LiveMeetingTranscript`) is one Apple Speech session per track, fed by `MeetingRecorder`'s sample observer, folded by the pure `LiveTranscriptAssembler`, display only and never persisted; the post-stop pipeline does not use it.
- `voxline/Learning/` — learning from corrections. After a dictation insert, `CorrectionWindow` anchors the text (`AnchorText`), polls the field once a second for 30 s keeping the last located change, and reads it once more; a new capture ends the window but it still finishes that final read. `RegionLocator` finds the region and never guesses (context shorter than 32 UTF-16 units counts as the field edge). `CorrectionClassifier` sorts edits into vocabulary fixes and style signals; `LearningStore` keeps style data in `learning.json`; `LearningCoordinator` is the one entry point the pipeline calls (`captureWillStart`, `didInsert`, `style(for:bundleID:)`). A style refresh in flight is dropped if Reset Learning runs or style learning is turned off. Commands and presets are not observed.
- `voxline/Modes/ModeStore.swift` — the per-app prompt table (27 app bundle IDs plus the `*` default mode: Slack, Zoom, Teams, Messages, Discord, Mail, Outlook, Spark, Word, Pages, Notes, Excel, PowerPoint, Keynote, Numbers, Terminal, iTerm, VS Code, Cursor, Xcode, and others). Add new apps here.
- `voxline/Transcription/Engines/` — one adapter per speech engine, each behind the `TranscriptionEngine` / `TranscriptionSession` protocols in `Transcription/TranscriptionEngine.swift`. `Transcription/TranscriptionEngines.swift` owns the instances and the selection; `TranscriptionService.swift` is WhisperKit's model manager.
- `voxline/Hotkey/` — two chords share one machine (`ChordSet`, `HotkeyStateMachine`, `ModifierTracker`). `KeyInterceptor.swift` is the active tap that swallows Esc while voxline is busy and fires the preset shortcuts (`KeyCombo`, `KeyComboValidator`; the presets themselves live in `Storage/PresetStore.swift`). Every `CGEvent` voxline posts goes through `Output/SyntheticKeys` and carries a tag that both taps ignore — never call `CGEvent.post` anywhere else.
- `voxline/Context/EditContextReader.swift` — reads the focused field for commands and presets through `AXTextElement` (tri-state `AXRead`): selection, a 12,000-unit window around the cursor, and a refusal for secure fields. `FieldWindow` and `EditPlanner` are the pure pieces. Every range that meets AX is a UTF-16 offset (`UTF16Range`), never a `String.Index` distance.
- `voxline/Output/` — `TextInserter` is the one entry point for putting text in a field. It chooses a strategy with `InsertionPlan` (Accessibility write via `AXTextEditor`, then paste via `PasteInjector`, then typing via `TypingInjector`). Electron/Chromium apps, browsers, terminals, and web content go paste-first. Two hidden defaults keys, with no UI: `voxline.insert.axFirst` (NO restores the paste-first order of earlier versions) and `voxline.insert.pasteFirstExtra` (an array of extra paste-first bundle IDs).
- `voxline/UI/MainWindowController.swift` — the one primary window: a sidebar with Home (`HomeView`/`HomeViewModel`: status, setup issues, permissions, recent meetings) and six settings pages (`voxline/Settings/Pages/`: General, Dictation, AI Provider, Commands, Vocabulary, Meetings) that share one `SettingsModel` per window build. It replaced the SwiftUI `Settings` scene and the Permissions window. Closing hides it; a Dock click or the menu bar's Open Voxline shows it. `voxline/MenuBar/ActivationPolicyController.swift` sets the Dock icon from `DockPolicy` (the `voxline.showInDock` setting, else "a titled non-panel window at normal level is visible or minimized") on every window event — never keep a set of tracked windows.
- `voxlineTests/` — Swift Testing unit/integration tests, one file per source file roughly 1:1.
- `voxlineTests/Bakeoff/` — the engine bake-off: fixture loading, `TranscriptScoring`, the decision rule, and `EngineBakeoffTests`, which is opt-in (`TEST_RUNNER_VOXLINE_BAKEOFF=1`) and skipped in CI. Fixtures are never committed. How to capture clips and run it: `docs/bakeoff.md`.
- `docs/release/RELEASE.md` — one-time Sparkle/notarization setup + release mechanics (maintainer-only, requires secrets you likely don't have).
- `docs/release/MANUAL_TESTS.md` — manual QA checklist for things automated tests can't cover (permissions dialogs, real hotkey presses, etc.).
- `docs/features.md` — competitive feature-matrix doc, not architecture.
- `scripts/build-local.sh` — build Release/Debug and install to `/Applications` with a real git-derived version stamp (plain `⌘R` in Xcode leaves `CFBundleVersion = 1`).
- `scripts/reset-local-state.sh`, `scripts/tail-logs.sh` — local dev utilities.
- `scripts/make-synthetic-bakeoff.sh` — renders text lines to `say` clips (WAV + reference `.txt`) for bake-off smoke runs.
- `scripts/tail-logs.sh` categories include `metrics` (per-dictation timings).
- `.github/workflows/ci.yml` — build + test on every push/PR.
- `.github/workflows/release.yml` — sign, notarize, DMG, Sparkle appcast; runs on `v*` tags.

## Build & test

```bash
open voxline.xcodeproj                 # Xcode, scheme "voxline"
./scripts/build-local.sh               # Release build, installs to /Applications
./scripts/build-local.sh --debug       # Debug build
./scripts/build-local.sh --no-install  # build only

xcodebuild test \
  -project voxline.xcodeproj \
  -scheme voxline \
  -destination 'platform=macOS'
```

Requires Xcode 26 and macOS 26 (Apple Silicon) — this is not cross-platform buildable. CI (`ci.yml`) runs the same test command with `CODE_SIGNING_ALLOWED=NO` on `macos-26` runners.

Engine integration tests (real Apple Speech / real WhisperKit) are skipped unless you run `TEST_RUNNER_VOXLINE_ENGINE_TESTS=1 xcodebuild test …`. Env vars reach the test runner only with the `TEST_RUNNER_` prefix.

## Conventions

- **Commit style**: Conventional Commits (`feat(scope): …`, `fix(scope): …`, `docs(scope): …`, `refactor(scope): …`, `release: …`, `chore: …`). Match `git log`.
- **DCO required**: every commit needs `Signed-off-by:` (use `git commit -s`).
- **Branching**: this project commits directly to `main` — don't default to proposing a feature branch unless asked.
- **Versioning**: `MARKETING_VERSION` (SemVer, in `project.pbxproj`) is bumped manually only when cutting a release. `CFBundleVersion`/build number is always the commit count on `main`, stamped automatically — never hand-edit it.
- **No comments explaining what code does** — this codebase favors clear naming; existing doc comments (`///`) are mostly on public-facing types/behavior contracts, not narration.
- Not sandboxed (hardened runtime only). App data lives in `~/Library/Application Support/voxline`; preferences in the standard defaults domain. `Storage/AppPaths.swift` owns every path.
- API keys live in the macOS Keychain via `Storage/KeychainStorage.swift` / `DataProtectionKeychain.swift` — never persist keys anywhere else (UserDefaults, plists, logs).
- Audio stays in memory, with two exceptions: meeting recordings (`~/Library/Application Support/voxline/meetings/<id>/`, deleted after `MeetingAudioRetention`, 14 days by default) and the hidden `voxline.debug.saveBakeoffClips` capture flag (off by default). The README's Privacy section promises this, so don't add another path.
- Hidden defaults keys, with no UI: `voxline.insert.axFirst`, `voxline.insert.pasteFirstExtra`, `voxline.debug.saveBakeoffClips`, `voxline.debug.meetingCapSeconds`, `voxline.llm.skipShortUtterances`, and `voxline.llm.model` (the cleanup model; the provider default when unset — the UI only sets the command and meeting-notes models).
- Field text and selections never go to logs or History: `AppLog` lines carry counts and reasons, and History keeps the instruction and the inserted text only. Learning keeps recent dictations and correction pairs only in `learning.json`. The README's Privacy section promises this.

## Releasing

Not something to do casually — see `docs/release/RELEASE.md` for the one-time Sparkle key / cert setup, and the README's "Releasing" section for the per-release checklist (bump `MARKETING_VERSION`, update `CHANGELOG.md`, tag `vX.Y.Z`, push). `release.yml` handles signing, notarization, DMG packaging, and publishing the Sparkle appcast to `gh-pages` — it requires repo secrets (Developer ID cert, notarization key, Sparkle private key) that most contributors won't have.
