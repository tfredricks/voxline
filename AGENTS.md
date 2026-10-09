# AGENTS.md

Guidance for coding agents working in this repo. Human contributors should read [CONTRIBUTING.md](CONTRIBUTING.md) and [README.md](README.md) instead.

## What this is

voxline is a native macOS menu-bar app (SwiftUI + AppKit, Swift Package Manager dependencies, no CocoaPods/Carthage). Hold a hotkey, speak, and it pastes cleaned-up text into the focused field:

1. `Audio/` captures mic input while the hotkey is held.
2. `Transcription/` runs Whisper on-device via [WhisperKit](https://github.com/argmaxinc/WhisperKit) (SPM dep: `argmaxinc/argmax-oss-swift`).
3. `Context/` assembles a context block (per-app mode prompt, focused-field AX info, custom vocabulary).
4. `LLM/` sends the transcript + context to Anthropic or OpenAI for cleanup (`AnthropicClient.swift` / `OpenAIClient.swift` behind `LLMService.swift`).
5. `Output/` pastes the result into the focused field and restores the clipboard.

`Pipeline/CapturePipeline.swift` orchestrates the above end to end; `AppState.swift` and `Hotkey/HotkeyStateMachine.swift` drive the hold-to-talk state.

## Directory map

- `voxline/Audio`, `Context`, `Diagnostics`, `Hotkey`, `LLM`, `MenuBar`, `Modes`, `Output`, `Permissions`, `Pipeline`, `Settings`, `Storage`, `Transcription`, `UI`, `Updates`, `Util`, `Wizard` — app source, one folder per concern.
- `voxline/Modes/ModeStore.swift` — the per-app prompt table (28 bundle IDs currently: Slack, Zoom, Teams, Messages, Discord, Mail, Outlook, Spark, Word, Pages, Notes, Excel, PowerPoint, Keynote, Numbers, Terminal, iTerm, VS Code, Cursor, Xcode, and others). Add new apps here.
- `voxlineTests/` — Swift Testing unit/integration tests, one file per source file roughly 1:1.
- `docs/release/RELEASE.md` — one-time Sparkle/notarization setup + release mechanics (maintainer-only, requires secrets you likely don't have).
- `docs/release/MANUAL_TESTS.md` — manual QA checklist for things automated tests can't cover (permissions dialogs, real hotkey presses, etc.).
- `docs/features.md` — competitive feature-matrix doc, not architecture.
- `scripts/build-local.sh` — build Release/Debug and install to `/Applications` with a real git-derived version stamp (plain `⌘R` in Xcode leaves `CFBundleVersion = 1`).
- `scripts/reset-local-state.sh`, `scripts/tail-logs.sh` — local dev utilities.
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

## Conventions

- **Commit style**: Conventional Commits (`feat(scope): …`, `fix(scope): …`, `docs(scope): …`, `refactor(scope): …`, `release: …`, `chore: …`). Match `git log`.
- **DCO required**: every commit needs `Signed-off-by:` (use `git commit -s`).
- **Branching**: this project commits directly to `main` — don't default to proposing a feature branch unless asked.
- **Versioning**: `MARKETING_VERSION` (SemVer, in `project.pbxproj`) is bumped manually only when cutting a release. `CFBundleVersion`/build number is always the commit count on `main`, stamped automatically — never hand-edit it.
- **No comments explaining what code does** — this codebase favors clear naming; existing doc comments (`///`) are mostly on public-facing types/behavior contracts, not narration.
- Not sandboxed (hardened runtime only). App data lives in `~/Library/Application Support/voxline`; preferences in the standard defaults domain. `Storage/AppPaths.swift` owns every path and `Storage/ContainerMigration.swift` moves 0.3.x container data on first launch.
- API keys live in the macOS Keychain via `Storage/KeychainStorage.swift` / `DataProtectionKeychain.swift` — never persist keys anywhere else (UserDefaults, plists, logs).

## Releasing

Not something to do casually — see `docs/release/RELEASE.md` for the one-time Sparkle key / cert setup, and the README's "Releasing" section for the per-release checklist (bump `MARKETING_VERSION`, update `CHANGELOG.md`, tag `vX.Y.Z`, push). `release.yml` handles signing, notarization, DMG packaging, and publishing the Sparkle appcast to `gh-pages` — it requires repo secrets (Developer ID cert, notarization key, Sparkle private key) that most contributors won't have.
