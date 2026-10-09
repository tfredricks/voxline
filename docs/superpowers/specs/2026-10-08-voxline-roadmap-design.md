# voxline roadmap — Wispr-class dictation and command mode

**Date:** 2026-10-08
**Status:** Approved roadmap. Each phase gets its own design spec and
implementation plan before any code is written.
**Supersedes:** the open items in `docs/issues.md` are no longer a standalone
backlog; they are mapped to phases below. `docs/features.md` remains a
reference matrix only.

## Why

voxline 0.3.1 transcribes well but feels slow and narrow next to Wispr Flow:

- The pipeline is strictly serial. Release the key, then Whisper runs over the
  whole buffer, then one LLM round trip, then a paste with fixed settle delays.
  Nothing overlaps, so every dictation pays the full sum at release.
- The App Sandbox blocks reading other apps' text through Accessibility. The
  selection read is a synthetic Cmd+C, cursor context comes back empty, and
  in-place edits go through the clipboard. voxline ships as a notarized DMG
  with Sparkle, not through the App Store, so the sandbox is a choice.
- Command mode is rewrite-only, requires a selection, and is triggered by a
  three-key hold. Wispr's is one two-key chord that edits, drafts, answers, or
  continues using the field contents, with or without a selection.
- When output is wrong, the speech engine misheard: names, jargon, dropped
  edges. The fix lives in the engine, not the prompt.

## Decisions

| Decision | Choice | Rationale |
|---|---|---|
| App Sandbox | Removed | Unlocks real AX reads and writes. Every serious Mac dictation tool is unsandboxed. Distribution is Developer ID + notarization, which does not require it. |
| Minimum macOS | 26.0 (was 14.0) | Makes Apple's SpeechAnalyzer a first-class engine candidate. Users on older macOS stay on 0.3.x. |
| Where audio goes | On-device by default; cloud STT is an opt-in provider using the user's own key | Keeps the privacy promise as the default while allowing the lowest-latency option for those who want it. |
| Transcription architecture | One engine protocol; local default picked by a measured bake-off | Choose from data on the user's own recordings, not from benchmarks on other people's audio. |
| Command mode scope | Full editing assistant; output always lands in the field | Rewrite, translate, summarize, expand, draft, continue, answer. The only guardrail is "return text", not "refuse to add content". |
| Command mode trigger | A second independent two-key chord, may share one modifier with the dictation chord | Matches Wispr (Fn dictates, Fn+Ctrl commands). No three-finger hold, no intent inference from speech. |
| Daily-use features in scope | Live transcript in the pill, learning dictionary with engine biasing, Esc to cancel plus retry, style learning | Chosen by the maintainer from the Wispr feature set and the open issues list. |
| Out of scope for this roadmap | Hands-free toggle mode, snippets, non-text voice actions, history search and re-insert, editable per-app prompts, full pill redesign | Not chosen. Can be scheduled after Learning. |
| Sequencing | Foundation first: platform → engine → command mode → meetings → learning | Each phase ships on its own, and the pipeline is rebuilt once, not twice. Phases 2 and 3 are independent and may run in parallel worktrees if the calendar needs compressing. |

## Roadmap at a glance

| Phase | Ships | Unblocks |
|---|---|---|
| 1. Platform reset | Sandbox off, macOS 26 floor, one-time data migration out of the container, sandbox workarounds deleted, AX messaging timeouts, per-dictation latency metrics, raw transcript kept in history | Everything below |
| 2. Transcription engine | Engine protocol, streaming capture, bake-off and default engine, vocabulary biasing, cloud opt-in, live transcript in the pill, bottom-center pill, Esc to cancel, retry, 5-minute recording cap | Fast commands in phase 3, engine hints in phase 5 |
| 3. Command mode v2 | Two-chord hotkey machine, AX reads of selection and field, generative editing prompt with structured result, AX in-place editor, refine buttons removed | Field reads reused by phase 5 |
| 4. Meetings | One-hour meeting recording (mic + system audio), on-device transcription and speaker diarization, LLM meeting notes written as Markdown | — |
| 5. Learning | Correction detection feeding the dictionary automatically, style profile per mode category, Learning section in Settings | — |

Rules that apply to every phase:

- Each phase is shippable on its own and leaves `main` releasable. No
  long-lived branches.
- Phases are milestones, not releases. Nothing bumps `MARKETING_VERSION`
  or dates a CHANGELOG section until a release is actually published; the
  version is picked then.
- Open items from `docs/issues.md` are fixed inside whichever phase touches
  that code (mapping at the end of this document). They are not scheduled
  separately.
- Every phase reads its numbers from the metrics phase 1 adds. "Faster" and
  "more accurate" are measured claims, with targets set in each phase's spec
  from the recorded baseline.
- Each phase's spec is written against the code as it exists when that phase
  starts, not against this document's guesses about it.

## Phase 1 — Platform reset

Goal: an unsandboxed app on macOS 26 that behaves exactly like 0.3.1, plus the
measurement hooks later phases need. Mostly deletion.

### Entitlements and target

- Remove `com.apple.security.app-sandbox`, `com.apple.security.network.client`,
  and both mach-lookup exception arrays (they existed only to make the sandbox
  work).
- Keep hardened runtime, `com.apple.security.device.audio-input` (required by
  the hardened runtime for microphone access), and the keychain access group
  (so the existing data-protection keychain items remain readable).
- `MACOSX_DEPLOYMENT_TARGET` to 26.0. CI runner to the macOS 26 image. Update
  the README requirements table and the Privacy section (the "sandboxed app"
  bullet goes away).

### Data migration

Unsandboxed, the app's storage locations change: preferences move from the
container to `~/Library/Preferences`, and the model cache can no longer live
under Documents (which now resolves to the real `~/Documents`). `AppPaths`
becomes the single owner of every path, rooted at
`~/Library/Application Support/voxline/`.

On first launch after the change, if the old container directory exists and a
migration marker is absent:

1. Copy the container's preferences plist into the app's `UserDefaults` domain
   (settings, history, vocabulary, first-run flag, mode overrides).
2. Move `modes.json` and the Whisper model cache into Application Support. The
   cache is ~1.5 GB; the move is a same-volume rename, not a copy.
3. Write the migration marker.

Keychain items survive because the access group is unchanged. If migration
fails at any step, the app still launches; it falls back to shipped defaults
and re-downloads the model. The failure is logged and shown once in a toast.

### Delete the sandbox workarounds

- `DefaultPasteEligibility`, `AXMenuBarInspector` (the per-paste menu-bar walk)
  and `AlwaysPasteEligible` go away. Paste eligibility becomes "the focused
  element is editable", read directly.
- `AXUIElementSetMessagingTimeout` is applied to every AX element the app
  creates (system-wide, app, and focused elements) so a hung target app can
  never beachball voxline.
- `DefaultAXContextProbe` and `AXFocusedTextSystem` are expected to start
  returning real data with no logic change; the phase spec verifies that
  against the code, and the comments documenting the sandbox limitation go.
- `DefaultSelectionSnapshot` (synthetic Cmd+C) is demoted to a fallback used
  only when the AX selected-text read returns nothing.

### Instrumentation

A `DictationMetrics` record per dictation or command:

| Field | Meaning |
|---|---|
| `audioDuration` | Seconds of captured audio |
| `captureTailMs` | Key release → last sample delivered |
| `transcribeMs` | Transcription time: the full transcribe call in phase 1; from phase 2, `finish()` → final text, plus a separate first-partial time |
| `cleanupMs` | LLM request → response |
| `insertMs` | Insert start → verified |
| `totalMs` | Key release → text in field |
| `engineID`, `modelID`, `wordCount`, `kind` (dictation / command) |

Logged through `AppLog`, kept in memory for the last 50, and shown in a
Diagnostics section of the About window with medians. `DictationHistoryItem`
gains `rawTranscript` alongside `cleanedText`; Clear History wipes both. The
raw transcript is needed by the phase 2 bake-off and the phase 5 learner, and
it makes "was it the engine or the LLM?" answerable from the History window.

### Also fixed here

- Dictating with no editable field focused reports it and copies the text
  instead of claiming success (issue 5).
- Keychain read errors are distinguished from "no key", and the wizard never
  commits an empty field over a read failure (issue 13).
- `AppCoordinator` moves out of `voxlineApp.swift` into its own file.

### Done when

- Fresh install and upgraded-from-0.3.1 install both dictate into Notes, Slack,
  VS Code, and Safari with identical results to 0.3.1.
- Settings, history, vocabulary, and the model cache survive the upgrade with
  no re-download, and both API keys remain readable without re-entry.
- The context block in a `VOXLINE_TRACE_LLM=1` run shows text before and after
  the cursor populated in a Cocoa app.
- The Diagnostics pane shows a baseline median for `totalMs` after 20
  dictations. That number is the input to phase 2's targets.

## Phase 2 — Transcription engine

Goal: text appears as fast as Wispr's, names are transcribed right the first
time, and the user can see and cancel what is happening.

### Engine protocol

```
protocol TranscriptionEngine {
    var id: EngineID { get }
    var capabilities: EngineCapabilities   // streaming partials, vocabulary hints, language detection
    func prepare() async throws            // download / compile / warm; idempotent
    func openSession(_ config: SessionConfig) async throws -> TranscriptionSession
}

protocol TranscriptionSession {
    func append(_ samples: [Float])        // 16 kHz mono, called from the audio tap path
    var partials: AsyncStream<Partial>     // (text, isStable) as the engine commits them
    func finish() async throws -> String   // flush and return final text
    func cancel()
}
```

`SessionConfig` carries the vocabulary hint list, language, and the mode
category (for engines that accept a domain hint). The audio service feeds the
open session continuously during recording; `CapturePipeline` no longer waits
for `takeSamples()` at release.

Engines, in a `Transcription/Engines/` folder:

- `AppleSpeechEngine` — `SpeechAnalyzer` / `SpeechTranscriber` (macOS 26).
  Streaming by design, no model download.
- `WhisperKitEngine` — the existing WhisperKit integration adapted to the
  protocol. Partials via WhisperKit's streaming transcriber; vocabulary via
  prompt tokens.
- `ParakeetEngine` — NVIDIA Parakeet through FluidAudio. Built only if the
  bake-off earns it a place.
- `CloudStreamingEngine` — WebSocket streaming to Deepgram or OpenAI's
  realtime transcription using the user's own key, stored in the keychain like
  the LLM keys. Opt-in in Settings with a clear "audio leaves your Mac" label.

Every candidate gets a minimal adapter so the bake-off can measure it. Only
the winner, and at most one fallback if the winner lacks vocabulary biasing,
gets production hardening, Settings UI, and a full test suite. The Settings
engine picker lists what shipped, plus the cloud option.

### Bake-off (first task of the phase)

A fixture-driven test target, `EngineBakeoff`, reads a folder of the
maintainer's own recordings (target: ~20 clips, 5–30 s each, heavy on real
names and jargon) with reference transcripts, runs every candidate engine, and
reports:

- Word error rate overall.
- Word error rate restricted to dictionary terms.
- Time from end of audio to final text, median and p90.
- Time from start of audio to first stable partial.

The decision rule is written into the phase 2 spec before the bake-off runs:
lowest dictionary-term error wins unless its finish latency is more than a
stated margin worse than the runner-up. The target skips in CI when fixtures
are absent. Fixtures are not committed.

The bake-off also answers two unknowns rather than assuming them: whether
Apple's engine accepts vocabulary hints, and whether FluidAudio's Parakeet
streaming is stable enough to ship.

### Vocabulary biasing

The dictionary feeds `SessionConfig.vocabularyHints`. Each engine maps that to
its own mechanism (prompt tokens, keyterms, contextual strings) or ignores it
if it has none. The hints also stay in the cleanup prompt as today, so the LLM
remains the second line of defense.

### Live transcript and the pill

- `AppState.liveTranscript` is updated from `partials`. The pill shows the last
  two lines of it while recording, with stable text in primary color and
  unstable text in secondary.
- The pill moves to a fixed bottom-center position, clamped to the visible
  frame of the screen that holds the mouse, with
  `.fullScreenAuxiliary` so it appears over full-screen apps. Near the cursor it
  would cover the text being dictated into. The review-session width logic is
  removed in phase 3; until then the pill is one fixed width sized for two
  lines of text.

### Cancel and retry

- Esc while recording discards the recording: session cancelled, no transcript,
  no LLM call, pill shows "Cancelled" briefly.
- Esc while thinking cancels the in-flight `finish()` and LLM task and resets to
  idle. The raw transcript, if one exists, is kept in history.
- Retry: on an error the pill shows a Retry control, and the menu bar gains
  "Retry last dictation", which re-runs cleanup from the stored raw transcript
  and inserts into the currently focused field.
- Esc is observed only while voxline is recording or thinking, via the existing
  event tap extended to key events for that window only.
- `maxRecordingDuration` rises to 5 minutes. The sample buffer no longer grows
  with recording length, so the old 60 s cap has no technical reason left.

### LLM step

Once transcription streams, the cleanup call dominates `totalMs`. In this phase:

- The cleanup request fires the instant `finish()` returns. Context capture
  already runs at recording start.
- The transcription preamble is trimmed; `maxOutputTokens` is budgeted from
  transcript length instead of a flat 1024.
- `stop_reason` / `finish_reason` are checked so a truncated or empty response
  is an error, not a silent empty paste (issues 14 and 18).
- Experiment, gated by metrics and off by default: a fast path that skips the
  LLM for utterances under a word threshold with no detected fillers. Promoted
  to a setting only if the metrics show a real win without accuracy loss.

### Folded-in issues

4 (quick-tap false error), 7 (pill off-screen and full-screen), 8 (mic
vanishing mid-recording: observe `AVAudioEngineConfigurationChange` and
finish gracefully), 14, 18, 21 (wizard offline dead end: if the default engine
needs no download the step disappears; otherwise the window gets a Quit
affordance), 23 (trailing syllable clipped: flush the converter on stop).

### Done when

- Median `totalMs` and dictionary-term error meet the targets the phase 2 spec
  sets from the phase 1 baseline.
- Live text is visible in the pill within the first second of speaking.
- Esc cancels at every stage without wedging the hotkey.

## Phase 3 — Command mode v2

Goal: Wispr's command workflow. Hold the command chord, say what you want done
to the selection or the field, release, and it happens in place.

### Hotkey: two chords, one machine

`HotkeyStateMachine` generalizes from one chord to a `ChordSet` of two:

- States: `idle`, `armed` (any chord key down, prewarm fires), `recording(kind)`,
  `finalizing(kind)`.
- On every flags change, the set of held chord keys is compared to each chord.
  Exactly equal to the dictation chord → dictation. Exactly equal to the
  command chord → command. From idle or armed, a strict superset of either
  → ignored (this also kills the Cmd+Shift+4 misfire, issue 11). Chords may
  share one modifier: holding the shared key arms; the second key decides.
- While recording, extra keys are ignored; release of any key of the active
  chord finalizes, as today.
- Defaults: Left Shift + Left Control dictates, Left Shift + Left Option
  commands.
- Migration: a stored `commandModifier` X with dictation chord A+B becomes
  command chord A+X. A stored "off" becomes the default command chord, or
  command mode off if that default collides with the dictation chord. The
  `commandModifier` setting and its picker are removed.
- The Settings chord recorder suspends the global tap while it listens
  (issue 10). Accessibility loss or `hotkeyEnabled` flipping mid-hold feeds a
  finalize instead of wedging (issue 12). Generic modifier mask bits are
  accepted alongside device-specific bits so remote and synthetic input works
  (issue 22). The fail-safe and reconcile timers run in common run-loop modes
  (issue 20).

### What the model sees

An `EditContext` read through AX at command start:

- The focused element's value, capped to a window around the cursor (cap set in
  the phase spec; on the order of 12k characters).
- Selected text and its range, cursor position.
- App name, bundle ID, window title, field role.
- Secure fields: command mode refuses with a toast; nothing is read.
- Fallback: when the AX value read returns nothing (empty AX tree), the
  synthetic Cmd+C reads the selection only; field contents are unavailable and
  the prompt says so.

### What the model returns

A structured result so insertion is never guessed:

```
{ "action": "replace_selection" | "insert" | "rewrite", "text": "..." }
```

- `replace_selection` — only valid when a selection exists. Text replaces it.
- `insert` — text is inserted at the cursor ("draft a reply", "continue this").
- `rewrite` — text is the full new field contents ("make the last paragraph
  shorter" with nothing selected). The app computes the minimal changed range
  between old and new contents and replaces only that range.
- No editable field focused: the text is copied to the clipboard with a toast.

The command system prompt replaces today's rewrite-only `transformPreamble`.
It frames the model as an editing assistant inside the user's field, gives it
the context above, and requires the structured result. The provider clients
gain a structured-output path (JSON mode or tool use) so parsing is reliable.

### How text lands

The 804-line `ClipboardInjector` splits into:

- `AXTextEditor` — in-place edit by setting `kAXSelectedTextRange` then
  `kAXSelectedText`. No clipboard involved; undoable with Cmd+Z in Cocoa apps.
  Primary path for dictation and commands.
- `PasteInjector` — clipboard write + synthetic Cmd+V, with the restore gated on
  the pasteboard change count so a slow app can never paste the user's old
  clipboard (issue 6) and the saved types keep their order (issue 17). Used
  when the AX write fails (Electron, some web views).
- `TypingInjector` — synthetic keystrokes with surrogate-pair-safe chunking
  (issue 16). Last resort.
- `TextInserter` — chooses the strategy and verifies the result.

Chord-release gating before a synthetic paste stays.

### Model choice

A `commandModel` setting, defaulting to the cleanup model. Drafting and
answering benefit from a stronger model than filler stripping does.

### Preset edit shortcuts

Added 2026-10-08 after using the phase 1 build: the keyboard-driven cousin of command
mode. Select text anywhere, press a shortcut, and a predefined instruction
runs through the same transform path with no recording. Defaults shipped as
a small editable table in Settings → Command:

| Shortcut | Preset |
|---|---|
| Option+1 | Fix grammar and typos, change nothing else |
| Option+2 | Make it concise |
| Option+3 | Make it professional |

Each row is a shortcut, a name, and the instruction text; the user can edit,
add, or remove rows. The hotkey monitor gains key-event handling for these
(phase 2 already adds it for Esc). A preset with no selection shows the same
"Select text to transform" toast as command mode. Caveat for the spec: on the
US layout Option+digit types a character (¡ ™ £), so a global shortcut
swallows it everywhere; the defaults stay, but the table must make remapping
obvious.

### Removed

Done early, in phase 1.

The post-dictation review session: `ReviewSession`, `RefinementDirective`,
`PillReviewActions`, `CapturePipeline.refine`, the hover-pause timers, and the
Shorter / Longer / Clearer buttons. "Shorter" becomes either "hold the command
chord and say shorter" or a preset shortcut on the selection. Issues 24–27
disappear with it.

### Done when

- With a selection in Notes, Slack, VS Code, and Gmail in Safari: "make this a
  bullet list", "translate this to Spanish", "summarize this" each replace the
  selection in place and Cmd+Z restores it.
- With no selection in a reply field: "draft a short reply agreeing to the
  Thursday time" inserts at the cursor using the thread text above.
- With no selection in a document: "make the last paragraph shorter" changes
  only that paragraph.
- A superset chord (dictation chord + Cmd) does nothing.
- Select a paragraph in Notes, press Option+2: it is replaced by a shorter
  version with no recording, and Cmd+Z restores it.

## Phase 4 — Meetings

Added 2026-10-09, scheduled ahead of Learning. Record a meeting of up to one
hour from the microphone and system audio, transcribe and diarize it on-device
after it stops, and write LLM meeting notes plus a speaker-labeled transcript
to a Markdown file. Full design: `2026-10-09-meeting-notes-design.md`.

## Phase 5 — Learning

Goal: stop correcting the same word twice, and have output sound like the
user without per-app prompt editing.

### Correction detection

After an insert, the app observes the focused element for a short window
(about 30 s, or until focus leaves) through `kAXValueChangedNotification` on
that element. It then diffs the inserted text against the same region's
current contents at the word level:

- A one- or two-token substitution where the new token is capitalized, absent
  from the system dictionary, or phonetically close to the old token is a
  vocabulary candidate.
- Clause deletions and rewrites are style signals, recorded as (before, after)
  pairs for the style profile, not as vocabulary.

Everything is computed locally. The observer is detached when the window ends.

### Dictionary

- Candidates are added automatically with a toast, "Learned: Argmax", and an
  undo. Auto-add is the right default for a feature whose point is fewer
  interruptions; the undo and the list keep it controllable.
- A Learned Words list in Settings (merged with the existing custom vocabulary
  list, with a source column) manages entries.
- The dictionary feeds the cleanup prompt (today) and the engine hints
  (phase 2), so a learned name is transcribed right the next time.
- Reset to Defaults no longer wipes the list without confirmation (issue 15).

### Style learning

- *Surrounding text.* The cleanup prompt already asks the model to match the
  register of text around the cursor. Unsandboxed, that text is finally there.
- *Style profile per mode category.* Every N dictations in a category (N set in
  the phase spec, around 20), the app asks the LLM to summarize the user's
  habits from recent final texts and recorded corrections into a short note:
  contractions, greetings and sign-offs, sentence length, lists versus prose,
  emoji. Stored locally per category, visible and editable in Settings,
  injected into that category's cleanup prompt. Two or three recent final texts
  from the same app ride along as examples of the user's voice. Caps keep the
  token cost bounded.
- `Mode` decoding is made field-tolerant before new fields are added (issue 19).

### Settings

A Learning section: toggles for word learning and style learning, the style
notes per category, and a reset.

### Privacy

All detection and storage is local. The style note and example texts are sent
to the user's LLM provider inside the prompt, exactly as the transcript is
today. The README's Privacy section says so.

### Done when

- Dictate a name the engine misspells, fix it in the field, dictate it again:
  it is transcribed correctly.
- After 20 Slack dictations, the Chat style note exists, reads sensibly, and a
  new Slack dictation visibly follows it.
- Turning both toggles off restores the pre-learning behavior exactly.

## Issue mapping

Every open item in `docs/issues.md` and where it is fixed:

| Issue | Phase |
|---|---|
| 4 quick-tap false "No audio captured" | 2 |
| 5 no editable field, silent success | 1 |
| 6 clipboard restore races slow apps | 3 |
| 7 pill off-screen / not over full-screen | 2 |
| 8 mic disappearing mid-recording | 2 |
| 9 per-paste menu-bar AX walk, no AX timeout | 1 |
| 10 chord recorder triggers live dictation | 3 |
| 11 superset chords misfire on OS shortcuts | 3 |
| 12 AX revoked mid-hold wedges recording | 3 |
| 13 keychain read errors look like "no key" | 1 |
| 14 OpenAI reasoning models paste nothing | 2 |
| 15 Reset wipes custom vocabulary | 5 |
| 16 typing fallback mangles emoji | 3 |
| 17 clipboard restore loses type order | 3 |
| 18 Anthropic stop_reason unchecked | 2 |
| 19 Mode Codable trap | Done (`category` decodes with `decodeIfPresent`) |
| 20 timers stall while menu open | 3 |
| 21 wizard dead end offline | 2 |
| 22 hotkey dead over Screen Sharing | 3 |
| 23 trailing audio dropped at release | 2 |
| 24–27 review-pill follow-ups | 24, 25, 27 done in phase 1 (pill removed); 26 done in phase 3 |
| 28 meeting timer chip truncates the time | Meetings follow-up, fix before publishing |

## Testing strategy

- **Unit (Swift Testing)**, per phase: the migration against temp directories;
  the metrics record; the two-chord machine including shared modifiers,
  superset rejection, and the modifier → chord migration; a fake engine that
  emits scripted partials to drive the pipeline and the pill; parsing and
  validation of the structured command result; the minimal-range diff; the
  correction classifier; style-profile prompt assembly.
- **Bake-off**: the fixture-driven `EngineBakeoff` target, skipped in CI
  without fixtures.
- **Manual** (`docs/release/MANUAL_TESTS.md` gains a section per phase):
  upgrade-from-0.3.1 migration, AX in-place edits across Cocoa, Electron, and
  web views, the pill over full-screen apps, Esc at each stage, permission
  revocation mid-hold, cloud engine opt-in and key handling.
- **Measured acceptance**: phase 1 records the baseline; phase 2's targets are
  derived from it; each later phase must not regress `totalMs` by more than a
  margin its spec states.

## Explicitly out of scope

Hands-free toggle mode, snippets, non-text voice actions (open app, web
search), history search and re-insert, editable per-app prompts and tone
presets in Settings, multi-language auto-detection, a full pill redesign
beyond position and live text. All are candidates for after Learning.

## Open questions deferred to phase specs

- Phase 2: the bake-off decision rule's latency margin; the exact set of
  engines that ship; whether Apple's engine accepts vocabulary hints; the
  short-utterance fast-path threshold; whether Esc is swallowed (which needs
  an active event tap) or passed through to the frontmost app as well.
- Phase 3: the field-contents cap; JSON mode versus tool use for the
  structured result per provider; which apps need the paste fallback by
  default.
- Phase 5: the observation window length; the phonetic-similarity threshold;
  N for style-profile refresh.
