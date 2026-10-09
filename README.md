<div align="center">

<img src="logo.png" alt="voxline app icon" width="160" />

# voxline

**Hold a key. Speak. Get polished writing.**

A native macOS dictation app that turns your voice into clean, written text — anywhere on your Mac. Speech runs on-device by default, via Whisper or Apple Speech. Cleanup runs through your own LLM API key, so you control the model, the cost, and the data path.

macOS 26+ · Apple Silicon · Bring your own API key

![Platform](https://img.shields.io/badge/platform-macOS-blue?style=flat-square)
&nbsp;
![Requires](https://img.shields.io/badge/macOS-26%2B-fa4e49?style=flat-square)
&nbsp;
![Status](https://img.shields.io/badge/status-early-yellow?style=flat-square)
&nbsp;
[![CI](https://img.shields.io/github/actions/workflow/status/tfredricks/voxline/ci.yml?branch=main&style=flat-square&label=CI)](https://github.com/tfredricks/voxline/actions/workflows/ci.yml)

</div>

> [!NOTE]
> voxline is in active development. Expect rough edges. The transcription pipeline is solid; the surface around it is still maturing.

## What it does

Most dictation tools dump a raw transcript with `um`, `uh`, half-finished sentences, and zero punctuation. voxline does the second step you actually want:

1. **Speech → text** locally on your Mac via Whisper or Apple Speech (or, if you opt in, OpenAI's cloud transcription).
2. **Text → polished writing** through a frontier LLM you choose (Claude or GPT).

Result: hold a hotkey, say what you mean — even messily — and watch clean prose appear in whatever field you're typing into.

## Features

- **Hold to talk** — press your hotkey, speak, release. Text appears in the focused field.
- **Works in any text field** — browser, email, IDE, terminal, Slack, Notes, Cursor, ChatGPT, anything that accepts a paste.
- **Your choice of speech engine** — Whisper (on-device, the default), Apple Speech (on-device, fastest), or OpenAI (cloud, opt-in). With the two on-device engines, audio never leaves your Mac.
- **Live transcript** — a small pill at the bottom of the screen shows your words as you speak, including over full-screen apps.
- **Esc to cancel, Retry to recover** — Esc throws away a dictation while it is recording or processing; if cleanup fails, Retry in the pill or the menu bar re-runs it on the same transcript.
- **AI cleanup, not raw dump** — fillers, false starts, and rambling are smoothed out. Punctuation and capitalization are added automatically.
- **Transform selected text by voice** — highlight text anywhere, hold your hotkey, and say how to change it: *"make this a bullet list"*, *"make this cleaner"*, *"make this shorter"*. voxline rewrites the selection in place and leaves it as a normal ⌘Z-undoable edit. No selection? It just dictates, as usual.
- **Context-aware per-app formatting** — voxline detects the frontmost app and tunes the output for it: terse Slack messages, structured email replies, code-comment style in your IDE, search-box one-liners. Ships with sensible defaults for 28 common apps out of the box.
- **Dictation history** — the last 25 dictations, cleaned text and raw transcript side by side, in a History window; click any row to copy it back to the clipboard.
- **Bring your own LLM key** — Anthropic or OpenAI, your account, your model, your costs. Keys live in macOS Keychain.
- **Menu-bar native** — no Dock icon, no clutter. Configurable hotkey, mic, speech engine, and provider.
- **Privacy-aware feedback** — clipboard is restored after paste; the system mic indicator turns off the moment you let go.

## How it works

```
┌──────────────── ON YOUR MAC ─────────────────┐
│  🎙 audio → Whisper / Apple Speech → text    │
│                                              │
│  Context block, assembled at press time:     │
│  • per-app mode prompt                       │
│  • focused-field AX (role, surroundings)     │
│  • custom vocabulary (canonical spellings)   │
└─────────────────────┬────────────────────────┘
                      │  transcript + context
                      ▼
┌────────── CLAUDE or GPT (your key) ──────────┐
│  strip fillers · fix self-corrections ·      │
│  match register · snap to vocab              │
└─────────────────────┬────────────────────────┘
                      │  polished writing
                      ▼
┌──────────────── ON YOUR MAC ─────────────────┐
│  paste into focused field                    │
│  (clipboard restored; AX/typing fallback)    │
└──────────────────────────────────────────────┘
```

### Speech engines

Pick one in Settings → General → Recognition → Engine.

| Engine | Runs | Best for |
|---|---|---|
| **Whisper** (default) | On your Mac | Most accurate in the project's bake-off; shows live text while you speak. Needs a one-time model download (below). |
| Apple Speech | On your Mac | Fastest: the transcript is ready about 0.1 s after you let go, and there is no model to download if macOS already has the language. Weaker on names and jargon in the project's bake-off. |
| OpenAI | OpenAI's servers | Cloud transcription (`gpt-4o-transcribe`) with your own OpenAI key. Audio leaves your Mac — see [Privacy](#privacy). Never the default. |

Switching engines prepares the new one in the background; if it needs a download, the menu bar shows progress and dictation waits. If OpenAI fails mid-dictation, voxline transcribes the same audio again on-device. Your custom vocabulary is applied during cleanup whichever engine you use. To measure the engines on your own voice, see [docs/bakeoff.md](docs/bakeoff.md).

### Whisper models (on-device)

| Model | Size | Best for |
|---|---|---|
| **Whisper large-v3 turbo** (default) | ~1.5 GB | Highest accuracy, multilingual |
| Whisper small.en | ~466 MB | Lightweight, English-only, fastest first run |

Models download on first use via [WhisperKit](https://github.com/argmaxinc/WhisperKit) and are cached locally. Switching models in Settings triggers an on-demand download — no app reinstall.

### Cleanup providers (cloud, your account)

| Provider | Default model | Where to get a key |
|---|---|---|
| **Anthropic** | claude-haiku-4-5 | https://console.anthropic.com/settings/keys |
| OpenAI | gpt-4.1-nano | https://platform.openai.com/api-keys |

Why cloud cleanup instead of a local model? Because the gap between a frontier LLM and what fits on a laptop is still enormous for prose quality. voxline's bet: trust on-device for the audio (which is sensitive), and let you pick best-in-class for the cleanup (which only sees a transcript). You decide which provider.

## Requirements

| | |
|---|---|
| **macOS** | 26 (Tahoe) or later |
| **Mac** | Apple Silicon — M1, M2, M3, M4, or any variant. Intel Macs are **not** supported. |
| **Speech engine** | One of three: Whisper (default) and Apple Speech run on-device; OpenAI is cloud and needs an OpenAI API key. |
| **RAM** | 8 GB minimum, 16 GB recommended (the default `large-v3-turbo` model is happier with headroom) |
| **Disk** | ~2 GB free if you use Whisper (`large-v3-turbo` ~1.5 GB, `small.en` ~466 MB). Models cache in `~/Library/Application Support/voxline`. Apple Speech needs none beyond macOS's own language assets. |
| **Network** | Required on first launch to download the Whisper model (or Apple's language assets, if macOS lacks them), and at runtime for AI cleanup. Transcription with Whisper or Apple Speech works offline once the model is cached. The OpenAI engine needs a connection for every dictation. |
| **Microphone** | Any input device macOS recognizes (built-in mic is fine). |

Apple Silicon is non-negotiable: voxline runs Whisper on the Apple Neural Engine via WhisperKit, and there is no ANE on Intel Macs.

## Getting started

**Download a signed build** from [Releases](https://github.com/tfredricks/voxline/releases) — the DMG is notarized by Apple, and the app checks for updates automatically via Sparkle.

Or build from source:

```bash
git clone https://github.com/tfredricks/voxline.git
cd voxline
open voxline.xcodeproj
```

Build and run from Xcode (⌘R), or use `./scripts/build-local.sh` to build Release and install straight to `/Applications`.

On first launch:

1. Grant **Microphone** and **Accessibility** when prompted (the app will guide you).
2. Pick your hotkey, mic, speech engine, and (for Whisper) model in the Settings window (⌘,). The default hotkey is **Right Cmd + Right Option** — change it if you'd rather use something else.
3. Drop in an Anthropic or OpenAI API key in the **Cleanup (AI)** section.
4. Hold the hotkey anywhere on your Mac and start talking.

### Permissions

| Permission | Why |
|---|---|
| Microphone | Capture your voice while the hotkey is held. Audio stays on your Mac unless you select the OpenAI engine. |
| Accessibility | Detect the global hotkey and paste into the focused field. |

Input Monitoring is **not** required — Accessibility alone is enough for the global hotkey. macOS may still surface an Input Monitoring entry for voxline; you can leave it off. The Debug pane shows its status for diagnostics only.

## Privacy

What stays local:

- 🎙 **Audio capture** — held in memory only and dropped as soon as the transcript exists. It is not written to disk (the one exception is a hidden developer flag, below).
- 🧠 **Speech-to-text with Apple Speech or Whisper** — both run on your Mac (Whisper on the Apple Neural Engine via WhisperKit). With either engine, no audio is sent anywhere.
- 🔑 **API keys** — stored in macOS Keychain. Not logged, not synced, not visible to other apps.
- 📜 **History** — the last 25 dictations, including raw transcripts, are stored in the app's preferences on your Mac. Clear them any time from the History window.

What goes to OpenAI, only if you select the OpenAI speech engine:

- 🎙 **Your audio** — it is streamed to OpenAI for transcription with your own OpenAI API key, and OpenAI's privacy policy applies. The Settings picker labels this engine "OpenAI — cloud, audio leaves your Mac", and it is never the default. While a cloud dictation is in progress, voxline also keeps that audio in memory so it can transcribe it on-device if the cloud fails; it is never written to disk.

What goes to your LLM provider:

- ✍️ **The transcript plus a small context slice** — voxline sends your transcript to Anthropic or OpenAI for cleanup, together with the frontmost app's name, the window title (up to 200 characters), the focused field's role, up to 500 characters of selected text, 200 characters before the cursor, 100 after it, and your custom vocabulary. Password fields never contribute their contents. Whatever provider's privacy policy applies (use enterprise tier or org-level keys if that matters to you).

A hidden developer flag:

- 💾 **`voxline.debug.saveBakeoffClips`** — when switched on, voxline saves each dictation's audio (as a WAV) and cleaned text under `~/Library/Application Support/voxline/bakeoff`, to build recordings for the [engine bake-off](docs/bakeoff.md). It is the **only** thing in voxline that writes audio to disk. It has no entry in Settings and is **off by default**; the bake-off doc shows how to turn it off and delete the clips.

voxline has **no telemetry, no analytics, and no first-party server**. The only network traffic is to whichever LLM provider you choose, OpenAI if you select its speech engine, and the one-time model downloads (Hugging Face for Whisper; Apple's own language assets for Apple Speech, if macOS lacks them).

## Good to know

- **Not sandboxed, on purpose** — voxline reads the focused field through the Accessibility API, which the App Sandbox blocks. The app ships notarized with the hardened runtime, and its data lives in `~/Library/Application Support/voxline`.
- **Settings live in one place** — single-page Settings window with a status strip up top showing what's wired up. Switching providers keeps both keys around for fast toggling.
- **Resilient hotkey** — when permissions are revoked or restored, voxline reconciles automatically without a relaunch.
- **Open source** — read the code, audit the data path, file an issue, send a PR.

## Acknowledgments

Built on the shoulders of:

- [WhisperKit](https://github.com/argmaxinc/WhisperKit) — on-device Whisper inference for Apple Silicon
- [Whisper](https://github.com/openai/whisper) — the original model from OpenAI
- [swift-transformers](https://github.com/huggingface/swift-transformers) — model hub and inference utilities
- The macOS dictation tools that paved the way (Whispr Flow, Superwhisper, Ghost Pepper, and others) — voxline borrows the hold-to-talk UX they all converged on.

## Releasing

Maintainer notes — the steps to cut a tagged release.

**Versioning.** voxline uses [SemVer](https://semver.org/) for the marketing version (`CFBundleShortVersionString` — e.g. `0.2.1`). Bump it manually when cutting a release:

- **Patch** (`0.2.0` → `0.2.1`) — bugfixes only
- **Minor** (`0.2.0` → `0.3.0`) — new features, backwards-compatible
- **Major** (`0.x` → `1.0.0`) — first stable release, or breaking changes after that

The build number (`CFBundleVersion`) is the commit count on `main` and stamps itself at build time — never edit it by hand.

**Release checklist.**

1. Update `MARKETING_VERSION` in `voxline.xcodeproj/project.pbxproj` (one line).
2. In `CHANGELOG.md`, move `[Unreleased]` items under a new `[X.Y.Z] - YYYY-MM-DD` heading.
3. Commit: `chore: release vX.Y.Z`.
4. Tag and push:
   ```bash
   git tag vX.Y.Z
   git push origin main --tags
   ```
5. Create a GitHub Release from the tag; paste the CHANGELOG entry as the body.

That's the whole flow. Between releases, `MARKETING_VERSION` stays put — every dev build reports the last released version with a higher commit-count build number.

## Contributing

Bug reports, feature ideas, and pull requests are welcome. See
[CONTRIBUTING.md](CONTRIBUTING.md) for build instructions, testing, the DCO
sign-off requirement, and the [Code of Conduct](CODE_OF_CONDUCT.md).

## License

voxline is licensed under the [Apache License, Version 2.0](LICENSE).

See [NOTICE](NOTICE) and [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) for required attributions. The "voxline" name and logo are reserved — see [TRADEMARK.md](TRADEMARK.md).
