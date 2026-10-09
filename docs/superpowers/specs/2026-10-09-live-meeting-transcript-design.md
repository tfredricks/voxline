# Live transcript during meetings

**Date:** 2026-10-09
**Status:** Approved design; implementation plan to follow.
**Builds on:** `2026-10-09-meeting-notes-design.md` (phase 4), which listed
this as "Approach 2, can be layered on later without changing the post-stop
pipeline". It does not change that pipeline.

## Goal

While a meeting records, show the last minute or so of what was said so you
can catch up on a sentence you missed. The recording timer chip gains a
disclosure; expanded, it shows the most recent lines labeled "Me" (your mic)
and "Them" (your Mac's sound output), with text that may still change shown
dim. Nothing about the recording, the files on disk, or the notes written
after Stop changes.

Not a goal: a full scrolling transcript, selectable text, speaker names, or
anything that survives the meeting. The Markdown file after Stop is the
record.

## What exists today (verified)

- `MeetingRecorder` owns two `MeetingAudioSource`s (`MicMeetingSource`,
  `SystemAudioTap`). Each delivers 16 kHz mono Float32 batches on a background
  thread through the `onSamples` closure `startSource(_:)` installs; the
  closure pads silence for alignment and appends to that track's
  `PCMTrackWriter`. A track restart calls `startSource` again with a fresh
  closure. `onSystemTrackLost` fires when the system track gives up.
- `TranscriptionSession` (`Transcription/TranscriptionEngine.swift`) accepts
  exactly that format through `append(_:)` from any thread and publishes
  `TranscriptPartial` snapshots (`stable` grows by appending, `volatile` is
  the unsettled tail) on `partials`. `cancel()` is idempotent and ends the
  stream.
- `AppleSpeechEngine.openSession` builds a fresh `SpeechAnalyzer` per call, so
  sessions are independent: two for a meeting plus one for a dictation held
  during it. `readiness()` reports `.ready`, `.needsPreparation`, or
  `.unavailable`; `prepare` is idempotent and cheap when ready. The engine
  instance is reached through `TranscriptionEngines.engine(for: .apple)`,
  whatever the dictation engine setting says.
- `MeetingTimerPanel` is a borderless, non-activating, draggable `NSPanel` at
  status-bar level on every Space, including full-screen ones. Its size comes
  from the hosting view's `fittingSize`, its frame from the pure
  `MeetingTimerLayout.frame(size:saved:visibleFrame:)`, and its position is
  autosaved under `voxline.meetingTimer`. `AppCoordinator.updateMeetingTimer`
  shows it while `MeetingController.phase` is `.recording` and
  `AppSettings.showMeetingTimer` is on; `meetingSettingsDidChange` re-runs that.
- `MeetingController.start()` builds the recorder through the injected
  `makeRecorder(directory)` closure, starts it, and sets `phase`. `stop()`
  forwards to the recorder; `recordingStopped` handles the rest.
- Settings → Meetings (`MeetingsSettingsPage`, `MeetingSettingsViewModel`)
  has the "Show recording timer" toggle; every change writes through to
  `AppSettings` and calls `onChange`, which reaches
  `AppCoordinator.meetingSettingsDidChange`.
- Tests already have `FakeTranscriptionEngine` / `FakeTranscriptionSession`
  (`voxlineTests/FakeTranscriptionEngine.swift`) and `FakeMeetingSource`
  (`MeetingRecorderTests.swift`).

## Decisions

| Decision | Choice | Rationale |
|---|---|---|
| How live text is produced | One Apple Speech `TranscriptionSession` per live track, fed the same batches the PCM writers get | Already streams from exactly this audio format; no model download; audio stays on the Mac. The engine protocol and the three adapters do not change. |
| Engine | Always Apple Speech, regardless of the dictation engine setting | Only on-device streaming engine with no download. Whisper's streaming is a re-transcribe loop sized for dictation, and the cloud engine would send meeting audio off the Mac, which the meetings spec forbids. |
| Lines | Derived from growth of each session's `stable` text; no timestamps | The catch-up view needs turn order, not time alignment. Avoids extending `TranscriptionSession` with timed segments (considered and rejected: touches every engine for precision the view does not need). |
| Labels | "Me" for the mic track, "Them" for the system track; no label in mic-only mode | Per-speaker names come from SpeakerKit after Stop and cannot be produced live. |
| Surface | The timer chip gains a chevron; expanded, it is a panel with the recent lines | Stays over full-screen call apps on every Space, like the chip. A main-window page would be hidden behind Zoom; an always-expanded panel would take screen space for an hour. |
| Expanded state | Remembered across meetings (`voxline.meetings.livePanelExpanded`, default collapsed) | You decide once; the chip opens the way you left it. |
| Setting | Settings → Meetings → "Live transcript" toggle, default on; effective only when "Show recording timer" is also on | Off means no sessions run and the chip looks exactly as today. With no chip there is no surface, so the sessions would be wasted work. |
| When the setting applies | Read at meeting start; a change mid-meeting takes effect at the next meeting | Keeps the recorder's start path the one place sessions are created. The chip and panel still follow the timer toggle live, as today. |
| Retention | In memory only; the last 50 lines; discarded at Stop | Live text is never written to disk or logged, matching the field-text rule in AGENTS.md. |
| Readiness | At start: `.ready` opens sessions; `.needsPreparation` runs `prepare` then opens them; `.unavailable` shows the reason in the panel | The meeting records normally either way. Batches that arrive before a session is open are dropped. |
| Dictation during a meeting | Dictated speech appears in the "Me" lines | Already accepted for the mic track in the meetings spec. |
| Gate | A measurement spike before the panel is built (below) | An hour-long `SpeechAnalyzer` session is untested here; dictation's cap is 5 minutes. |

## Components

New files in `voxline/Meetings/`:

| Unit | Job | Depends on |
|---|---|---|
| `LiveTranscriptAssembler` | Pure. `mutating func apply(_ partial: TranscriptPartial, track: MeetingRecorder.Track) -> LiveTranscript`. Keeps, per track, the last `stable` string and the current `volatile`. When the new `stable` extends the old one, the trimmed suffix is a finished segment. A finished segment joins the newest line when that line is from the same track; otherwise it starts a new line. A `stable` that is not an extension of the old one (a restarted session) is taken whole as a new segment. Blank segments are ignored. Keeps at most `maxLines` (50), dropping the oldest. | — |
| `LiveMeetingTranscript` | `@Observable @MainActor`. Owns one session per live track and the assembler; publishes `transcript: LiveTranscript` and `availability` (`preparing`, `listening`, `unavailable(String)`). `start(tracks:)` resolves readiness, prepares if needed, opens the sessions, and consumes each `partials` stream into the assembler on the main actor. `trackLost(_:)` cancels that track's session. `stop()` cancels every session and ends consumption. Conforms to `MeetingSampleObserver`: `samples(_:track:)` forwards straight to the matching session's `append`, which is audio-thread safe; the session table is a lock-protected dictionary so the forward never touches the main actor. | `TranscriptionEngine` (Apple), `LiveTranscriptAssembler` |
| `MeetingSampleObserver` (protocol, in `MeetingAudioSource.swift`) | `func samples(_ samples: [Float], track: MeetingRecorder.Track)`, `@Sendable`, called on the source's background thread after the writer has the batch. | — |

Changes to existing code:

- `MeetingRecorder`: an optional `observer: MeetingSampleObserver?` init
  parameter. `startSource(_:)` calls `observer?.samples(batch, track: track)`
  after `writer.append(batch)`. Silence padding is not forwarded; the live
  session does not need alignment. Restarts keep feeding the same observer.
  Nothing is forwarded after `stop()`, which the sources already guarantee.
- `MeetingController`: `makeRecorder` becomes
  `(MeetingDirectory, MeetingSampleObserver?) -> MeetingRecording`, and a new
  `makeLiveTranscript: @MainActor () -> LiveMeetingTranscribing?` returns nil
  when the setting is off or the engine cannot be reached. `start()` builds
  the live transcript first, passes it to `makeRecorder`, and after the
  recorder has started calls `live.start(tracks:)` with `[.mic]` or
  `[.mic, .system]` from `recorder.systemTapStarted`. `onSystemTrackLost`
  also calls `live.trackLost(.system)`. `recordingStopped` calls `live.stop()`
  and clears it. A new `private(set) var liveTranscript: LiveMeetingTranscribing?`
  is non-nil only while recording. `LiveMeetingTranscribing` is the protocol
  the controller and panel see, so controller tests use a fake.
- `AppCoordinator.buildMeetings`: supplies both closures. `makeLiveTranscript`
  reads `AppSettings()` (`showMeetingTimer && meetingLiveTranscript`) and uses
  `engines?.engine(for: .apple)`. `updateMeetingTimer` passes
  `state.meetings?.liveTranscript` to the panel.
- `AppSettings`: `meetingLiveTranscript: Bool` (key
  `voxline.meetings.liveTranscript`, absent reads as on) and
  `meetingLivePanelExpanded: Bool` (key `voxline.meetings.livePanelExpanded`,
  absent reads as off).
- `MeetingSettingsViewModel` / `MeetingsSettingsPage`: a `liveTranscript`
  toggle under Recording, below "Show recording timer", disabled while the
  timer toggle is off, with the caption "Shows the last few things said in the
  recording timer. Transcribed on this Mac with Apple Speech; nothing is
  saved."
- `MeetingTimerPanel` → keeps its name and panel setup; `show` takes the live
  transcript (nil when the feature is off or unavailable for this meeting) and
  hosts `MeetingLivePanelView`.
- `MeetingTimerLayout`: `resized(_ frame: CGRect, to size: CGSize, visibleFrame:)`
  keeps the frame's top-left corner while the size changes, then clamps to the
  visible frame. Used when the panel expands or collapses.

## Data model

```swift
struct LiveLine: Equatable, Identifiable, Sendable {
    let id: Int                      // monotonic, for SwiftUI identity
    var track: MeetingRecorder.Track
    var text: String
}

struct LiveTranscript: Equatable, Sendable {
    var lines: [LiveLine] = []                            // oldest first, ≤ 50
    var volatile: [MeetingRecorder.Track: String] = [:]   // unsettled tail per track
}

enum LiveAvailability: Equatable { case preparing, listening, unavailable(String) }
```

`MeetingRecorder.Track` gains `Hashable` and a `liveLabel` (`"Me"`, `"Them"`).
In mic-only mode the view hides labels.

## Lifecycle

**Start.** `MeetingController.start()`:

1. `let live = makeLiveTranscript()` (nil when off or the engine is missing).
2. `let recorder = makeRecorder(directory, live)`; `try recorder.start()` as
   today. If that throws, `live` is discarded without ever starting.
3. `live?.start(tracks: recorder.systemTapStarted ? [.mic, .system] : [.mic])`.
   Inside, in a task: readiness → prepare if needed → `openSession` per track
   with an empty `SessionConfig` (no vocabulary hints: this view is for
   catching up, and the hints are tuned for dictation; the notes after Stop
   still get the vocabulary) → store sessions → `availability = .listening`
   → consume partials. Any failure sets `.unavailable(reason)` with the error's
   `localizedDescription`, logs it through `AppLog.meetings` (reason only), and
   leaves the meeting recording.
4. `liveTranscript = live`; `phase = .recording(...)` as today. The panel
   reads `liveTranscript` when it shows.

**During.**

- Each source batch reaches the writer, then the observer. Before the
  sessions are open, `samples(_:track:)` finds no session and returns.
- Partials arrive on the main actor through the consumption task; each one
  passes through the assembler and replaces `transcript`.
- A track restart changes nothing for the session. `trackLost(.system)`
  cancels the "Them" session; "Me" continues. The session's own partial
  stream ending (an engine error mid-meeting) sets `availability` to
  `.unavailable` only when no session remains; otherwise that track just
  stops producing lines.
- Dictation during the meeting opens its own Apple session as today; both run.

**Stop** (user, cap, or failure). `recordingStopped` calls `live.stop()`:
every session is cancelled, the consumption tasks end, `liveTranscript`
becomes nil, and the panel hides as today. The live text is gone; the
post-stop pipeline starts from the `.pcm` files exactly as before.

**Quit during recording** already stops the recorder on a confirmed quit; the
live transcript stops with it.

## The panel

`MeetingLivePanelView` replaces `MeetingTimerChip` as the panel's root view.

- **Header** is the chip as today (red dot, elapsed time) plus, when a live
  transcript exists for this meeting, a chevron button at the trailing edge.
  The header stays draggable through `isMovableByWindowBackground`; only the
  chevron is a button, so a drag that starts on the time still moves the
  panel.
- **Collapsed**: header only. Pixel-identical to today's chip when the feature
  is off.
- **Expanded**: the header plus a body 360 pt wide and 150 pt tall. The body
  is a `ScrollView` of the lines, oldest at the top, pinned to the bottom
  through `ScrollViewReader` whenever `transcript` changes. Each line shows its
  label (`Me` / `Them`, caption, secondary) and text (12 pt). Below the lines,
  each track with a non-empty `volatile` shows it as one more line in tertiary
  color. With no lines yet the body reads "Listening…"; while `availability`
  is `.preparing`, "Preparing Apple Speech…"; when `.unavailable(reason)`,
  "Live transcript unavailable: \(reason)".
- **Toggling** writes `meetingLivePanelExpanded`, recomputes the hosting view's
  `fittingSize`, and sets the frame from `MeetingTimerLayout.resized`, so the
  top-left corner stays put and the panel grows downward, clamped to the
  screen. The single autosave name stays; `frame(size:saved:visibleFrame:)`
  already ignores the saved size.
- The panel never becomes key, so it never steals focus from the call.
- Accessibility: the header keeps its "Meeting recording" label; the body is
  a list whose rows read "Me: …" / "Them: …".

## Settings

Settings → Meetings → Recording:

```
Show recording timer      [on]
Live transcript           [on]   (disabled when the timer is off)
  Shows the last few things said in the recording timer. Transcribed on
  this Mac with Apple Speech; nothing is saved.
```

Reset to Defaults restores the toggle to on and does not touch the remembered
expanded state. A change mid-meeting applies at the next meeting; the caption
does not need to say so.

## Gate: measurement spike (first task)

Two unknowns, measured before the panel is built, with a throwaway harness in
the test target that is opt-in like the engine tests
(`TEST_RUNNER_VOXLINE_ENGINE_TESTS=1`) and skipped in CI:

1. **Session longevity.** Feed one `AppleSpeechSession` a 60-minute clip
   (two `say` voices tiled, as the meetings spike did) as fast as the analyzer
   accepts it. Pass: final results keep arriving through the last minute, the
   process's resident memory does not climb more than 100 MB over the run, and
   `cancel()` returns promptly at the end.
2. **Real-time cost.** Run two sessions on live-rate synthetic audio for five
   minutes while a `MeetingRecorder` with fake sources writes the same audio.
   Pass: average CPU for the voxline test process under 25 % of one core on
   the maintainer's M3 Pro, and the writers report no dropped batches.

If 1 fails: `LiveMeetingTranscript` restarts each session every 10 minutes at a
quiet moment (its `volatile` empty for 2 s); the assembler already treats a
non-extending `stable` as a fresh segment. If 2 fails: the live transcript
defaults to off and the toggle's caption says it costs battery. Results are
appended to this spec as the meetings spec did.

## Privacy

Live text lives in memory in `LiveMeetingTranscript` and the panel, never on
disk and never in `AppLog` (log lines carry session counts and failure
reasons only). It is produced by Apple Speech on the Mac; nothing goes to a
provider. The README's Privacy section's Meetings bullet gains one sentence
saying so, and the settings caption says "nothing is saved".

## Docs

- `CHANGELOG.md` Unreleased → Added, under the meetings entry: the live
  transcript in the timer chip and its toggle.
- `README.md`: the meeting-notes feature bullet mentions the live view; the
  Privacy Meetings bullet gains the sentence above.
- `AGENTS.md` Meetings line: live transcript is Apple Speech sessions fed from
  the recorder, display only.
- `docs/release/MANUAL_TESTS.md` Meetings section: the checks below.
- `docs/features.md`: no change (it is a reference matrix).

## Testing (Swift Testing)

- `LiveTranscriptAssemblerTests`: a growing `stable` yields one line; two
  growths on one track join into one line; a growth on the other track starts
  a new line; `volatile` is kept per track and cleared when it settles; a
  non-extending `stable` becomes a fresh segment; blank growth is ignored;
  the 51st line drops the oldest; ids stay monotonic across drops.
- `LiveMeetingTranscriptTests` with `FakeTranscriptionEngine`: `start` opens
  one session per track with no hints; `samples` reaches the right session;
  samples before open are dropped silently; emitted partials update
  `transcript` on the main actor; `trackLost(.system)` cancels only that
  session; `stop` cancels every session and leaves `transcript` untouched;
  `.unavailable` readiness and a throwing `openSession` set `availability`;
  `.needsPreparation` calls `prepare` first.
- `MeetingRecorderTests`: the observer receives every batch per track after
  the writer; a restart keeps delivering to the same observer; padding is not
  forwarded; nothing arrives after `stop`.
- `MeetingControllerTests` with a fake `LiveMeetingTranscribing`: it is
  started with the right tracks after the recorder starts, never started when
  the recorder fails to start, stopped and cleared on stop, told about the
  lost system track, and `liveTranscript` is nil when the factory returns nil.
- `MeetingTimerLayoutTests`: `resized` keeps the top-left corner, grows
  downward, and clamps at the bottom and right edges.
- `MeetingSettingsViewModelTests` / `MeetingSettingsTests`: the toggle writes
  through and calls `onChange`; the key's absent default is on; the expanded
  default is off.

## Manual tests (`docs/release/MANUAL_TESTS.md`, Meetings section)

- [ ] Start a meeting; the chip has a chevron. Expand: "Listening…", then
      your own words appear under "Me" within a few seconds, bright once
      settled, dim while changing.
- [ ] On a call with headphones, the other side appears under "Them"; turns
      interleave in speaking order.
- [ ] In-person (system tap denied or silent): lines carry no label.
- [ ] Collapse and expand: the top-left corner stays put; near the bottom of
      the screen the panel stays on screen.
- [ ] Expanded state survives Stop and the next Start; the position too.
- [ ] Drag the panel by the time; the chevron toggles without moving it.
- [ ] Hold the dictation hotkey mid-meeting: dictation works; the words show
      under "Me".
- [ ] Unplug headphones mid-meeting: "Me" keeps updating after the restart.
- [ ] Stop: the panel disappears; the notes after processing are unchanged
      from a meeting recorded with the toggle off.
- [ ] Settings → Meetings → Live transcript off: the chip is exactly the old
      chip, and `scripts/tail-logs.sh` shows no live session opened. Timer off
      disables the toggle.
- [ ] Full-screen Zoom or Teams: the expanded panel stays visible over it.
- [ ] One-hour meeting: lines still arrive in the last minute; Activity
      Monitor's CPU for voxline over the hour noted in the spec results.

## Done when

- The spike results are in this spec and both gates pass or their fallbacks
  are built.
- Every unit test above passes with the suite green in CI.
- Every manual check above passes on the maintainer's Mac, including the
  one-hour run.
- A meeting recorded with the toggle on produces byte-identical `.pcm`
  tracks to one recorded with it off, given the same input (verified in
  `MeetingRecorderTests` with fake sources).

## Open questions resolved here

- **Vocabulary hints for the live sessions?** No. The hints are tuned for
  dictation, the view is for catching up, and the post-stop transcript still
  uses them.
- **Should the live text seed the post-stop pipeline?** No. Whole-file Whisper
  plus SpeakerKit alignment stays the source of the notes; the live text is
  never kept.
- **Why not show the live transcript in Home?** Hidden behind a full-screen
  call. The chip is already on every Space.

## Out of scope

Timestamps on lines, selectable or copyable live text, a full-transcript
window, speaker names live, a live transcript when the timer chip is hidden,
live text from the cloud engine, and any change to the post-stop pipeline or
the Markdown output.

## Spike results (2026-10-09)

Machine: Apple M3 Pro, 36 GB. Audio: four `say` sentences in two voices, tiled to 60 min.

| Gate | Result | Pass |
|---|---|---|
| Hour-long session: finals in minutes 55–60 | yes; stable length 49,277 (minute 54) → 53,935 chars (minute 60) | ✓ |
| Hour-long session: resident memory | 168 → 111 MB | ✓ |
| Hour-long session: `cancel()` | 1 ms | ✓ |
| Two sessions + recorder, 5 min real time | 3 % of one core; no samples lost | ✓ |

The hour of audio was fed in 958 s wall (about 3.8x real time). Stable text grew by about 880 characters every minute through the whole hour.

One early exit was not reproduced. The first gate 1 run ended at about 9m44s (17:04 start, 17:13 relaunch) when the test runner exited with code 0 before the test finished: no crash report, no assertion output, cause unknown. The rerun under `caffeinate -i`, with the host's resident memory sampled every 30 s (flat at 110 to 150 MB), ran the full hour of audio and passed. The decision below stands with this caveat, and the one-hour manual test in `docs/release/MANUAL_TESTS.md` (added in Task 9) re-checks it. A live session dying silently near 10 minutes is the failure the 10-minute restart fallback exists for.

Decision: sessions run uninterrupted for the hour; live transcript defaults on.
