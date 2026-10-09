# Phase 2 — Transcription engine (0.5.0)

**Date:** 2026-10-08
**Status:** Written and approved autonomously overnight. Todd delegated every
decision in this phase ("trust you to make good decisions"). Each decision
below carries its reason so it can be overturned in review.
**Roadmap:** Phase 2 of `2026-10-08-voxline-roadmap-design.md`.

## Goal

Text appears as fast as Wispr's, names come out right the first time, and the
user can see and cancel what is happening. Concretely: the speech engine runs
while the user talks instead of after they let go, the pill shows the words as
they are recognized, and Esc stops everything.

## Baseline

The 0.4.0 checklist asks for a 20-dictation median. Only four dictations were
recorded before this spec was written (unified log, 2026-10-08 21:34–21:37,
WhisperKit large-v3 turbo, `gpt-4.1-nano`):

| | transcribe | cleanup | insert | total |
|---|---|---|---|---|
| Median of 4 | 716 ms | 950 ms | 370 ms | **2,151 ms** |

This is the provisional baseline. Todd replaces it with the 20-dictation number
when he runs the 0.4.0 checklist; the targets below are relative and move with
it.

Two facts from a spike against the macOS 26.6 SDK shape the design:

- Apple's `SpeechTranscriber` (preset `.progressiveTranscription`) returned its
  final text **117–120 ms** after the last audio buffer on a 10-second clip.
  Prepare took 40–60 ms. The en-US assets were already installed, and the spike
  needed no Speech Recognition prompt.
- `AnalysisContext.contextualStrings` was accepted but changed nothing in
  `SpeechTranscriber`'s output ("LangGraph" still came out "land graph",
  "Fredricks" as "Fredericks"). Treat Apple's engine as having no vocabulary
  biasing until the bake-off says otherwise. Whisper's prompt tokens are the
  only real biasing mechanism on the table. (Amended: WhisperKit 1.0's
  prompting turned out to be broken, so no on-device engine biases; see
  Decisions.)

## Targets

Measured on the default engine, 20 dictations, same LLM model as the baseline:

| Metric | Target |
|---|---|
| `transcribeMs` median (finish → final text) | ≤ 300 ms |
| `totalMs` median | ≤ 1,500 ms (−30% vs baseline) |
| First partial on screen | within 1 s of speech start |
| Dictionary-term miss rate (bake-off) | no more than 5 points worse than WhisperKit's |

## Decisions

| Question (roadmap "deferred to phase spec") | Decision | Why |
|---|---|---|
| Engines that ship | Apple `SpeechTranscriber`, WhisperKit (streaming), OpenAI Realtime transcription (cloud, opt-in) | Apple is the latency winner and needs no 1.5 GB model; WhisperKit is the incumbent on-device engine and the accuracy reference (its prompt biasing turned out to be broken in WhisperKit 1.0; see the amended row below); one cloud option covers "best accuracy, audio leaves the Mac". |
| Parakeet / FluidAudio | Not built this phase | It adds a new dependency and another ~600 MB model to compete in a slot Apple already fills on latency and Whisper fills on biasing. The engine protocol makes it a one-file adapter later if both shipping engines miss the targets. |
| Deepgram | Not built | One cloud provider is enough. OpenAI reuses the OpenAI key most users already store for cleanup, so there is no new key UI. |
| Bake-off decision rule | See "Decision rule" below; latency margin **300 ms** | Written before any run, as the roadmap requires. |
| Default engine | Chosen by the rule. A synthetic smoke run (TTS clips) sets it provisionally tonight; Todd's real clips confirm or flip it | No real recordings exist yet. |
| Apple vocabulary hints | Passed through `AnalysisContext` anyway; capability flag off | Harmless if ignored; the bake-off measures whether they help. |
| WhisperKit vocabulary hints (amended during implementation) | Not sent; capability flag off | WhisperKit 1.0's `TextDecoder` runs its stop checks while forcing prompt tokens, so any `promptTokens` make large-v3 turbo return empty text (token trace in the Task 5a report). A local workaround also disabled timestamp rules and broke streaming confirmation. LLM cleanup applies the vocabulary for every engine. Revisit when WhisperKit fixes prompting upstream. |
| Esc: swallow or pass through | **Swallowed**, only while voxline is recording or thinking | Passing Esc to the frontmost app would close compose windows and popovers in Slack, Mail, and IDEs exactly when the user is dictating into them. A separate active event tap on its own thread does the swallowing, so a busy main thread cannot stall the keyboard. Phase 3's preset shortcuts reuse it. |
| Short-utterance fast path threshold | ≤ 6 words, no filler tokens; hidden defaults flag, off | Ships as the roadmap's experiment. Not exposed in Settings. |
| Recording cap | 5 minutes, with a toast when it hits | Roadmap. |
| Where the raw transcript goes on Esc during thinking | History (as both raw and cleaned text) and the Retry slot | Roadmap: "kept in history". |
| Retry for commands | Not supported; Retry is dictation only | A command retry needs the original selection, which may be gone. |
| Cloud failure mid-dictation | The pipeline re-transcribes the in-memory audio with the on-device default engine | A network blip must not lose a dictation. Audio is retained in memory only while a cloud session is active, and never written to disk. |

## Architecture

### Engine protocol

New file `voxline/Transcription/TranscriptionEngine.swift`:

```swift
enum EngineID: String, Codable, CaseIterable, Sendable {
    case apple = "apple"
    case whisperKit = "whisperkit"
    case openAIRealtime = "openai-realtime"
}

struct EngineCapabilities: OptionSet, Sendable {
    static let streamingPartials   // emits partials while audio arrives
    static let vocabularyHints     // SessionConfig.vocabularyHints changes output
    static let sendsAudioOffDevice // cloud
}

enum EngineReadiness: Equatable, Sendable {
    case ready
    case needsPreparation(downloadMB: Int?)   // nil = size unknown (OS assets)
    case unavailable(String)                  // user-facing reason
}

struct SessionConfig: Equatable, Sendable {
    var vocabularyHints: [String]
    var locale: Locale
}

struct TranscriptPartial: Equatable, Sendable {
    var stable: String      // committed; will not change
    var volatile: String    // current guess for the tail; may change
}

@MainActor
protocol TranscriptionEngine: AnyObject {
    var id: EngineID { get }
    var metricsID: String { get }          // e.g. "apple:en_US", "whisperkit:<variant>"
    var capabilities: EngineCapabilities { get }
    func readiness() async -> EngineReadiness
    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws  // idempotent
    func openSession(_ config: SessionConfig) async throws -> any TranscriptionSession
}

protocol TranscriptionSession: AnyObject, Sendable {
    func append(_ samples: [Float])        // 16 kHz mono Float32; any thread; never blocks on I/O
    var partials: AsyncStream<TranscriptPartial> { get }
    func finish() async throws -> String   // flush, return final text, finish `partials`
    func cancel()                          // idempotent; finishes `partials`; a pending finish() throws CancellationError
}
```

`Transcribing` and the `takeSamples()` path are deleted. `TranscriptionService`
stays as WhisperKit's model manager (download, load, prewarm) and is used by
the WhisperKit engine.

### Audio path

`AudioCaptureService` stops accumulating samples. It gains
`onSamples: (@Sendable ([Float]) -> Void)?`, read once at `start()` and called
synchronously on the tap thread with each converted chunk. `onLevel` keeps its
main-actor hop for the meter.

A conversion lock guards the converter. `stop()` removes the tap, then, under
the lock, drains the converter with an end-of-stream input and delivers the
remainder before stopping the engine. Every sample converted before the
function returns has been delivered, so no tail is lost (issue 23). The epoch
check that discarded in-flight chunks goes away with the main-actor hop.

An `AVAudioEngineConfigurationChange` observer calls
`onInterrupted: (() -> Void)?` on the main actor when the engine stops during
a capture. The pipeline treats that as a release plus a toast:
"Microphone disconnected — stopped recording" (issue 8).

`StreamingSampleRouter` (new, `voxline/Pipeline/`) sits between capture and
session. It is a lock-protected, `@unchecked Sendable` final class:

- `append(_:)` updates `sampleCount` and `peak` synchronously, then forwards to
  the attached session or holds the chunk in a pending list until one attaches.
  Because count and peak update together, a quick tap can no longer show
  samples with peak 0 (issue 4).
- `attach(_:)` flushes the pending list into the session, in order, then
  forwards directly.
- With `retainsAudio == true` it also keeps every sample. That is used for
  cloud sessions (fallback) and for the developer capture flag (bake-off
  clips). Otherwise nothing is kept after forwarding.
- `close()` drops further input.

The session opens asynchronously after recording starts, and early audio waits
in the router, so opening an engine never clips the first word.

### Pipeline

`CapturePipeline` takes a `TranscriptionEngineProviding`, whose `current`
returns the selected engine, instead of a `Transcribing`. It also takes a
`vocabulary: () -> [String]` provider.

**Start.** The existing status gate applies. The pipeline creates a router,
sets `capture.onSamples`, starts capture, and opens the session in a task. When
the session opens it attaches to the router and starts a partials consumer
that writes `state.liveTranscript` on the main actor and records the time of
the first non-empty partial. Context capture still starts here. It now also
snapshots the focused field and the frontmost bundle ID, so mode resolution no
longer costs AX round trips after release.

**Finish.** On release:

1. Stop capture, which flushes the tail, and set status to `.thinking`.
2. A recording of zero samples, or under 0.3 s of audio, ends quietly with
   status back to idle and the session cancelled.
3. A peak of 0 means silent capture, which keeps today's error.
4. Await the session open. If it failed, report "Couldn't start <engine>:
   <reason>".
5. `finish()`. The time this call takes is `transcribeMs`.
6. Mode resolution (from the start snapshot), cleanup, history, and insert, as
   today.

The final transcript is stored in `state.retryTranscript` before cleanup
starts.

**Cloud fallback.** When the engine has `.sendsAudioOffDevice` and either the
open or `finish()` fails with anything other than cancellation, the pipeline
opens an on-device session on `EngineID.onDeviceDefault`. It feeds that
session the router's retained audio, finishes it, and logs the fallback. The
toast reads "Cloud transcription failed — used on-device".

**Cancel.** `cancel()` is the single entry point for Esc:

- While recording: stop capture, cancel the session, close the router, cancel
  the context tasks, go to idle, and toast "Cancelled". The hotkey machine is
  still in `.recording`. The later chord release makes `finalizeRecording`
  return immediately, because status is no longer `.recording`, and
  `recordingFinished()` returns the machine to idle. The stop blip does not
  play for a cancelled recording.
- While thinking, before insert begins: bump the pipeline's generation token,
  cancel the in-flight finish or LLM task, and return status to idle at once.
  If a raw transcript exists, record it in history (raw and cleaned both set
  to it) and keep it as `retryTranscript`. Toast "Cancelled".
- During insert: ignored. The insert is not cancellable; see issues.md,
  "rejected findings", for why a cancel there double-inserts.

`finalizeRecording()` must return to its caller within 100 ms of `cancel()`,
whether or not the engine or the HTTP call honors cancellation. The finalize
work runs in a child `Task`. The caller awaits a done signal that either the
work or `cancel()` resolves. Every state write after an `await` checks that
the generation token is unchanged, so a late result is dropped.

`state.isCancellable` is true while recording, and while thinking until
insert begins. It arms the Esc interceptor.

**Retry.** `retryLastDictation()` runs when `retryTranscript != nil` and
status is idle or error. It does a fresh context capture and mode resolution
for the currently focused app, then cleanup and insert, records history, and
records no metrics. On success it leaves `retryTranscript` in place, so a
paste into the wrong field can be retried again. `startRecording` clears
`retryTranscript` along with `lastTranscript` (existing privacy hygiene).

### Engines (`voxline/Transcription/Engines/`)

**`AppleSpeechEngine`.** `SpeechTranscriber(locale:preset: .progressiveTranscription)`
with the locale from `SpeechTranscriber.supportedLocale(equivalentTo: .current)`,
falling back to en-US. If neither is supported, readiness is `.unavailable`.

- `prepare()` installs assets through `AssetInventory` when the status is not
  `.installed`, reporting the request's `Progress`, then reserves the locale.
- `readiness()` maps `AssetInventory.status`.
- Each session builds a `SpeechAnalyzer` with `modelRetention: .processLifetime`
  and sets `contextualStrings[.general]` to the hints. It converts appended
  Float32 chunks to the analyzer's `bestAvailableAudioFormat` (Int16 16 kHz in
  the spike) and yields them as `AnalyzerInput` into an `AsyncStream`.
- Results with `isFinal` append to `stable`; non-final results replace
  `volatile`.
- `finish()` ends the input stream, calls `finalizeAndFinishThroughEndOfInput()`,
  drains results, and returns `stable` trimmed. `cancel()` calls
  `cancelAndFinishNow()`.
- Capabilities: `.streamingPartials` only.
- `Info.plist` gains `NSSpeechRecognitionUsageDescription` defensively.

**`WhisperKitEngine`.** Wraps `TranscriptionService`: readiness comes from the
model cache, `prepare()` is the existing download plus prewarm, and `metricsID`
is today's `engineID` string. Sessions keep the full buffer under a lock and
run a rolling pass on a background task. The pass fires each time at least
1.0 s of new audio has arrived since the last one. It is modeled on
WhisperKit's own `AudioStreamTranscriber`, which can't be used directly
because it owns the mic.

- Each pass transcribes the buffer with `clipTimestamps = [lastConfirmedEnd]`.
  All segments but the last two are confirmed into `stable`; the rest become
  `volatile`.
- `finish()` waits for any in-flight pass, then runs one final pass from
  `lastConfirmedEnd` over the complete buffer and returns confirmed text plus
  the final segments.
- Vocabulary: hints are ignored (see the amended decision row; WhisperKit
  1.0 prompting is broken).
- Capabilities: `.streamingPartials`.

**`OpenAIRealtimeEngine`.** A WebSocket transcription session against OpenAI's
Realtime API with `gpt-4o-transcribe`, authenticated with the OpenAI key
already stored for cleanup (`KeychainAccount.openai`). The implementing task
verifies the event names and session shape against OpenAI's current docs
before writing code.

- Audio is resampled 16 → 24 kHz PCM16 and sent as base64 append events.
- Server VAD is on, so pauses produce completed segments; those segments are
  the partials.
- `finish()` commits the remaining buffer and waits for its completed event
  (10 s timeout). The final text is the completed segments joined in item
  order.
- The prompt carries the vocabulary hints.
- Readiness is `.unavailable("Add an OpenAI API key in Settings → API Keys")`
  without a key. It never downloads.
- Capabilities: `.streamingPartials`, `.vocabularyHints`, and
  `.sendsAudioOffDevice`.

### Engine selection and preparation

`AppSettings.transcriptionEngine: EngineID` lives under the key
`voxline.transcription.engine`. When the key is absent it falls back to
`EngineID.default`. `EngineID.onDeviceDefault` is the same value, constrained
to an on-device engine; the cloud engine can never be the default.

`TranscriptionEngines` (new, `@MainActor`) owns one instance of each engine,
conforms to `TranscriptionEngineProviding`, and exposes `select(_:)`.

The coordinator's prepare flow is generalized from "is the Whisper model
cached" to `readiness()`:

- `.ready` → warm the engine. `prepare()` is still called, cheaply, for
  WhisperKit's prewarm.
- `.needsPreparation` → today's download window and statuses, with progress
  from `prepare(progress:)`.
- `.unavailable` → `.error(reason)`.

Settings → General → Recognition:

- An **Engine** picker:
  - "Apple Speech — on-device, fastest"
  - "Whisper — on-device"
  - "OpenAI — cloud, audio leaves your Mac"
- The Whisper model picker shows only when Whisper is selected.
- With OpenAI selected, a caption says audio is sent to OpenAI with the user's
  OpenAI key, and a warning appears if no key is stored.

Switching engines triggers the existing single-flight background prepare.
Reset to Defaults resets the engine.

**Wizard (issue 21).** The model-download step becomes "Speech engine". It is
skipped entirely when the selected engine's readiness is `.ready` at wizard
start. Otherwise it shows progress, and its footer gains a "Quit Voxline"
button, so a failed offline download is never a dead end.

### Vocabulary biasing

`SessionConfig.vocabularyHints` comes from `CustomVocabularyStore.load()` at
recording start. Each engine maps the hints to its own mechanism as described
above. The cleanup prompt keeps the vocabulary line, so the LLM remains the
second line of defense, and its canonical-spelling rule already repairs
"lang graph" → "LangGraph".

### Live transcript and the pill

- `AppState.liveTranscript: TranscriptPartial?` is set by the partials
  consumer and cleared at idle. `AppState.pipelinePhase` is
  `.transcribing`, `.cleaning`, or `.inserting`, valid while thinking.
- The pill is anchored bottom-center on the visible frame of the screen that
  holds the mouse when it appears, 24 pt above the frame's bottom edge.
  `.fullScreenAuxiliary` is added to its collection behavior (issue 7). It
  re-anchors bottom-center on every size change.
- Sizes:
  - Recording with no text yet, and toasts: 32 pt tall. Toasts are as wide as
    the text, up to 440 pt.
  - Any state that shows transcript text: 440 pt wide and 64 pt tall.
  - The 140 pt idle width is gone.
- Recording: top row has the waveform, the "Command" cue, and the elapsed time
  (`m:ss` past 60 s). Below it are the last two lines of the live transcript,
  head-truncated, stable text in primary color and volatile text in secondary.
- Thinking: a spinner and the phase label ("Transcribing…" / "Cleaning up…"),
  with the final transcript's last two lines in secondary color once
  `finish()` returns.
- Error with a retryable transcript: the error's first sentence plus a
  **Retry** button, shown for 8 s. Only in this state does the panel accept
  mouse events (`ignoresMouseEvents = false`). It stays non-activating, so
  clicking Retry does not steal focus from the target field.
- The menu bar gains "Retry last dictation", enabled when
  `retryTranscript != nil`.

### Esc interceptor

`EscapeKeyInterceptor` (new, `voxline/Hotkey/`):

- An active `CGEventTap` (`.cgSessionEventTap`, `.headInsertEventTap`,
  `.defaultTap`) for keyDown and keyUp.
- It runs on a dedicated thread with its own run loop. It is installed and
  removed alongside the hotkey tap by the coordinator's reconcile loop.
- A lock-protected `isArmed` flag mirrors `state.isCancellable`.
- When armed, a keyDown of keycode 53 with no command, option, control, or
  shift flags is swallowed, and `onEscape` is dispatched to the main actor.
  The matching keyUp is swallowed too.
- Everything else, and everything while disarmed, passes through untouched.
- A disabled-by-timeout tap is re-enabled.
- If the tap can't be created, Esc cancel is unavailable and this is logged.
  Nothing else changes.

### Recording cap

`HotkeyMonitor.maxRecordingDuration` becomes 300 s. When it fires, the
pipeline shows "Stopped at 5 minutes" after inserting. A buffer only grows
with recording length for WhisperKit sessions (19 MB at 5 min) and retained
cloud audio.

### LLM step

- **Preamble trim.** `LLMService.systemPrompt(mode:context:)` includes the
  Context paragraph only when the context block is non-empty, and the
  custom-vocabulary paragraph only when vocabulary is non-empty. The rest is
  unchanged.
- **Output budget.** `maxOutputTokens` is
  `clamp(ceil(transcript.utf8.count / 4 × 1.5) + 256, 256…4096)` for cleanup.
  OpenAI models whose id starts with `o1`, `o3`, `o4`, or `gpt-5` get an extra
  4,096 for hidden reasoning tokens.
- **Truncation and refusals (issues 14, 18).** New `LLMError.truncated` and
  `LLMError.refused` with user-facing text:
  - Anthropic decodes `stop_reason`: `max_tokens` → truncated, `refusal` →
    refused.
  - OpenAI decodes `finish_reason` and optional `content`: `length` →
    truncated, `content_filter` → refused, nil or blank content → bad response
    shape.
  - All of these follow the existing failure path: raw transcript to the
    clipboard, error shown, Retry offered.
- **Fast path.** Behind the hidden defaults key `voxline.llm.skipShortUtterances`,
  off by default. A transcript of ≤ 6 words containing none of
  um / uh / er / ah / hmm / "you know" / "I mean" skips cleanup and inserts
  the engine text. `cleanupMs` is recorded as 0. Not shown in Settings.

### Metrics

- `DictationMetrics` gains `firstPartialMs: Int?` (recording start → first
  non-empty partial).
- `transcribeMs` becomes finish → final text.
- `captureTailMs` is release → capture stopped and flushed.
- Timing moves to `ContinuousClock`.
- `DictationMetricsStore.median(_:kind:)` filters by kind. The insert median
  skips rows with `insertMs == 0` (copy path).
- The Diagnostics view shows medians over dictations only, plus a
  "first words" median.
- The log line adds `firstPartial=` and `skipCleanup=`.

### Bake-off

- **Suite.** `voxlineTests/Bakeoff/EngineBakeoffTests.swift` is a Swift
  Testing suite, `.enabled(if: BakeoffFixtures.isPresent)`, so it is skipped
  in CI.
- **Fixtures.** They are read from `$VOXLINE_BAKEOFF_DIR` (pass as
  `TEST_RUNNER_VOXLINE_BAKEOFF_DIR` to `xcodebuild`), else
  `~/Library/Application Support/voxline/bakeoff/`. Each clip is
  `<name>.wav` (any format `AVAudioFile` reads) plus `<name>.txt` (reference).
  An optional `terms.txt` holds one dictionary term per line. Fixtures are
  never committed.
- **Run.**
  - Each engine gets a fresh session per clip, fed in 100 ms chunks at real
    time. `VOXLINE_BAKEOFF_SPEED` multiplies the pace.
  - Hints come from `terms.txt`.
  - WhisperKit runs only if large-v3 turbo is cached.
  - OpenAI runs only with `VOXLINE_BAKEOFF_CLOUD=1`, and is reported but never
    eligible as default.
- **Scoring (`TranscriptScoring`, pure, unit-tested in CI).**
  - Normalization: lowercase, punctuation stripped except apostrophes,
    whitespace collapsed.
  - WER is word-level Levenshtein over the normalized words.
  - Terms are compared in compact form: lowercase alphanumerics only, so
    "lang graph" and "LangGraph" match, because the LLM repairs spacing and
    case. A term's hits are `min(occurrences in reference, occurrences in
    hypothesis)`.
  - Miss rate is `1 − Σhits / Σreference occurrences`.
  - Latency figures: finish latency (`finish()` call → return) median and p90,
    and first-partial latency median.
- **Report.** A markdown table goes to stdout and to
  `<fixtures>/bakeoff-report.md`, followed by the rule's verdict.

**Decision rule** (fixed before any run):

1. Only on-device engines are eligible.
2. An engine whose WER is more than 5 points worse than the best eligible WER
   is out.
3. If the two lowest miss rates are within 2 points, the lower median finish
   latency wins.
4. Otherwise the lowest miss rate wins, unless its median finish latency is
   more than 300 ms worse than the runner-up's, in which case the runner-up
   wins.

**Clip capture for real fixtures.** The hidden defaults key
`voxline.debug.saveBakeoffClips` is off by default. When it is on, the router
retains audio, and each successful dictation writes `<timestamp>.wav` (16 kHz
mono) and `<timestamp>.txt` (the cleaned text, as a draft reference to
correct) into the fixtures folder. This is the only path that writes audio to
disk; it is documented in the README's Privacy section as a developer flag.

`scripts/make-synthetic-bakeoff.sh <lines.txt> <dir>` renders each line with
`say`, rotating voices, to 16 kHz WAV plus `.txt`, for smoke runs.

### Folded-in issues

| Issue | Fix |
|---|---|
| 4 quick-tap false "No audio captured" | Router updates count and peak together; under 0.3 s is a quiet no-op |
| 7 pill off-screen / not over full-screen | Bottom-center anchoring, `.fullScreenAuxiliary` |
| 8 mic disappearing mid-recording | Configuration-change observer → early finish + toast |
| 14 OpenAI reasoning models paste nothing | `finish_reason`, optional content, reasoning headroom |
| 18 Anthropic `stop_reason` unchecked | Decoded and mapped |
| 21 wizard dead end offline | Step skipped when ready; Quit button otherwise |
| 23 trailing audio dropped | Synchronous delivery + converter flush on stop |

0.4.0 final-review carry-overs fixed here:

- Medians filtered by kind.
- `ContinuousClock`.
- `isModelCached` no longer creates directories. `AppPaths` gains a
  non-creating `modelCacheDirectoryIfPresent()`.

The AX carry-overs move to phase 3, which rewrites that code:

- AX `""` → Cmd+C fallback.
- `focusedFieldIsSecure` fails open.
- Late AX write double insert.

### Out of scope

Parakeet, Deepgram, language auto-detection, promoting the fast path to a
setting, and any change to command mode beyond what cancel and the pill need.

## Testing

- **Unit (Swift Testing):**
  - `StreamingSampleRouter`: ordering across attach, count/peak consistency,
    retain on and off, close.
  - `FakeEngine` / `FakeSession` emitting scripted partials, driving
    `CapturePipeline`:
    - live transcript updates
    - first-partial metric
    - quiet short-recording path
    - session-open failure
    - cancel while recording
    - cancel while thinking, including a finish that never returns
    - cancel ignored during insert
    - retry
    - cloud fallback
  - Engine selection and readiness mapping in the coordinator's prepare
    decision (extracted as a pure function).
  - LLM budget function, stop and finish reason mapping, preamble assembly
    with and without context and vocabulary, fast-path predicate.
  - `TranscriptScoring`.
  - Metrics medians by kind.
  - Pill anchoring math (pure function of screen frame and size).
  - Esc interceptor decision function (keycode and flags → swallow?) as a pure
    function.
- **Integration (skipped without assets):** `AppleSpeechEngine` transcribes a
  synthesized `say` clip when the en-US assets are installed, checked by WER
  under 25% against the source text.
- **Bake-off:** fixture-driven, as above.
- **Manual:** `MANUAL_TESTS.md` gains a 0.5.0 section covering:
  - live text in the pill
  - the pill over a full-screen app, and on a second display
  - Esc while recording, while transcribing, while cleaning, and during insert
  - Retry from the pill and from the menu
  - unplugging a USB mic mid-recording
  - switching engines
  - OpenAI with Wi-Fi off (fallback)
  - the wizard with the engine already ready
  - the 5-minute cap

## Done when

- The bake-off has run on synthetic clips and the default engine is set by the
  rule; the run on Todd's real clips is the remaining manual gate.
- With the default engine, the medians over 20 dictations meet the targets
  table.
- Live text is visible in the pill within a second of speaking (streaming
  engines).
- Esc cancels at every stage without wedging the hotkey, and a late engine or
  LLM result never lands after a cancel.
- No regression: dictation, command mode, the no-field copy path, and history
  all behave as in 0.4.0.

## Synthetic bake-off result (provisional)

Run 2026-10-08 23:38 CDT on the maintainer's Mac: 20 clips rendered with
`say` (five voices rotating) from realistic dictation sentences, 15 dictionary
terms, real-time pacing, `scripts/make-synthetic-bakeoff.sh`. The clips and
the full report stay outside the repo.

| Engine | WER % | Term miss % | Finish median ms | Finish p90 ms | First partial median ms |
|---|---|---|---|---|---|
| Apple Speech (apple:en_US) | 18.4 | 48.5 | 120 | 155 | 1041 |
| WhisperKit (large-v3 turbo) | 4.6 | 12.1 | 731 | 947 | 2506 |

**Verdict:** WhisperKit. Apple Speech is out at step 2 of the rule (more than
5 WER points worse than the best), so `EngineID.default` stays `.whisperKit`.

Caveats. TTS audio is clean and evenly paced, with no room noise and almost
no trailing silence; Todd's own clips decide. Apple mangled jargon the TTS
voices pronounce oddly ("Cuban eats" for Kubernetes); Whisper split
CamelCase names ("lang graph", "Whisper Kid") that the cleanup prompt's
vocabulary rule repairs, which the term metric already credits.

Consequence for the targets: with WhisperKit as the default, finish latency
(~730 ms median) misses the ≤ 300 ms `transcribeMs` target. Streaming gives
WhisperKit live partials, but a short dictation confirms nothing before
release, so the final pass still decodes the whole clip. Two follow-ups are
recorded: finish early when the audio after the last rolling pass is silent
(Task 12 below), and, for Todd to decide, a hybrid that shows Apple's fast
partials while Whisper produces the final text.

**Update (Task 12, early finalize).** WhisperKit now runs a rolling pass when
speech pauses and, at release, reuses the last pass when only silence
(relative to the speaker's level) follows it. Same 20 clips with 600 ms of
trailing silence: finish median 475 ms, p90 654 ms, 15 of 20 clips finished
without a final pass; WER 4.9% (+0.3, one clip's wording), term miss 12.1%
(unchanged). Without trailing silence: median 661 ms. The bake-off loader
was also found to clip up to ~64 ms off each clip and was fixed (Task 13), so
earlier numbers ran on slightly shortened audio. The ≤ 300 ms target is
still missed with WhisperKit; Apple Speech meets it (~120 ms) but loses the
accuracy comparison on these clips.
