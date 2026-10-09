# Phase 4 — Meetings (0.7.0)

**Date:** 2026-10-09
**Status:** Approved in brainstorming with Todd, section by section.
**Roadmap:** Phase 4 of `2026-10-08-voxline-roadmap-design.md`, scheduled ahead
of Learning (now phase 5, 0.8.0).

## Goal

Record a meeting of up to one hour, in person or on a call, and get meeting
notes plus a speaker-labeled transcript as a Markdown file a few minutes after
stopping. Audio never leaves the Mac; only the text transcript goes to the
user's LLM provider, as dictation transcripts do today.

## Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Audio sources | Microphone and system audio as two separate tracks; mic-only when system audio is unavailable or denied | Remote participants on Zoom/Teams/Meet are only in system output. Separate tracks make "Me" free and exact. |
| System audio API | Core Audio process tap (`CATapDescription` + aggregate device) | macOS 26 floor makes it available. Needs only the "System Audio Recording" permission, not Screen Recording; no screen-capture indicator. |
| Speaker attribution | Mic track is "Me"; system track is diarized into "Speaker 1…N" | Per-speaker labels were chosen over Me/Them. |
| Diarization | On-device SpeakerKit (pyannote v4 community-1, Core ML), after recording stops | Already a product of the `argmax-oss-swift` package voxline depends on. Keeps audio local. |
| When transcription runs | After stop, whole-file WhisperKit per track ("record now, process after") | Dictation pipeline untouched; SpeakerKit's `addSpeakerInfo(to: [TranscriptionResult])` aligns WhisperKit output natively; whole-file Whisper is more accurate on long audio; the same pipeline re-runs on retained audio. Cost: a few minutes' wait after stop. |
| Output | One Markdown file per meeting in a user-chosen folder; notification opens it | Works with Obsidian/iCloud/any editor; almost no new UI. No in-app meetings browser. |
| Notes content | One fixed template, structured LLM output | Chosen over editable prompts and multiple templates. |
| Notes model | New "Meeting notes model" setting; empty falls back to the command model, then the cleanup model | Long transcripts reward a stronger model than cleanup's. |
| Start/stop | Menu bar items plus an optional toggle shortcut (unset by default) | Hold-to-talk does not fit an hour. No automatic start: recording people needs a deliberate act. |
| Length | Hard cap at 60:00, warning notification at 55:00 | Requested limit. The stop at 60:00 behaves exactly like a manual stop. |
| Audio retention | Kept 14 days by default, then deleted; configurable | Allows "Regenerate notes" and re-diarization without keeping audio forever. |
| Concurrency | One meeting at a time; Start is disabled while a meeting is recording or processing | Keeps Neural Engine and memory use bounded. Audio is safe on disk while waiting. |
| Dictation during a meeting | Keeps working | The meeting recorder owns its own `AVAudioEngine`; dictation's capture is unchanged. Dictated speech also lands in the mic track; accepted. |

## Gate: measurement spike (first task)

The only real unknown is post-stop processing time and memory on Todd's Mac.
Before building anything else, a throwaway harness runs on a 60-minute
two-voice recording (real, or synthesized with `scripts/make-synthetic-bakeoff.sh`
style TTS):

- WhisperKit whole-file transcription with word timestamps and VAD chunking,
  using the model the app's Whisper engine already uses.
- SpeakerKit `diarize` on the same file.
- Peak resident memory across both.

Targets: total ≤ 4 minutes and peak memory ≤ 1.5 GB. If transcription misses,
try a smaller Whisper variant for meetings only and record the WER difference
on the bake-off clips; if that is still over, stop and revisit the approach with
Todd before proceeding. Results are appended to this spec.

## Architecture

New folder `voxline/Meetings/`. Every unit below the recorder is behind a
protocol so `MeetingPipeline` is tested with fakes, following the existing
`PipelineProtocols.swift` pattern.

| Unit | Job | Depends on |
|---|---|---|
| `SystemAudioTap` | Creates a process tap of all system output excluding voxline's own process (so voxline's blips are not recorded), wraps it in a private aggregate device, and delivers buffers from an IOProc. Reports permission denial distinctly from other failures. | Core Audio |
| `MeetingRecorder` | Owns one recording: its own `AVAudioEngine` on the selected input device, plus `SystemAudioTap`. Converts each source to 16 kHz mono through `CaptureConverter` and appends Int16 PCM to a raw file per track. Enforces the 55:00 warning and 60:00 stop. Publishes elapsed time and per-track health. | `SystemAudioTap`, `CaptureConverter` |
| `MeetingTranscriber` | Whole-file WhisperKit transcription of one track with word timestamps; returns `[TranscriptionResult]`. Loads its own WhisperKit instance for the job and releases it afterwards. | WhisperKit |
| `MeetingDiarizer` | SpeakerKit `diarize` on the system track, then `addSpeakerInfo(to:)` on that track's transcription; returns speaker-labeled segments. | SpeakerKit |
| `TranscriptMerger` | Pure function: (mic segments, system segments) → ordered `[MeetingUtterance]` (speaker, start, end, text). Labels mic as "Me"; joins consecutive utterances from the same speaker when the gap is under 2 s; drops echoed mic segments (below). | — |
| `MeetingNotesWriter` | Builds the notes prompt, makes one structured-output request through `LLMService`, renders the Markdown file. | `LLMService` |
| `MeetingPipeline` | Orchestrates transcribe → diarize → merge → notes → write → notify for one meeting directory. Publishes a stage for the menu ("Transcribing 1/2", "Identifying speakers", "Writing notes"). | All of the above, via protocols |
| `MeetingStore` | Meeting directory layout, `meta.json` state, retention cleanup at launch and daily, unfinished-meeting discovery, file naming, the regenerate entry point. | `AppPaths` |

Touch points in existing code:

- `AppCoordinator`: constructs and wires the recorder, pipeline and store; the
  toggle shortcut is registered through the same `KeyCombo` / `KeyInterceptor`
  machinery as command presets.
- `MenuBarContent`: Start Meeting Recording / Stop Meeting Recording, a status
  line, the Regenerate Notes submenu.
- Menu-bar icon: a recording variant while a meeting records.
- A small elapsed-time chip (borderless floating panel, draggable, hideable in
  Settings) while recording.
- `SettingsView`: a new Meetings section (below).
- `AppPaths`: `meetingsDirectory()` →
  `~/Library/Application Support/voxline/meetings/`.
- `Info.plist`: `NSAudioCaptureUsageDescription`.
- `project.pbxproj`: add the `SpeakerKit` product from `argmax-oss-swift`.

`CapturePipeline`, `HotkeyStateMachine` and the dictation capture path do not
change.

## On disk

Per meeting, `~/Library/Application Support/voxline/meetings/<uuid>/`:

| File | When | Contents |
|---|---|---|
| `meta.json` | Created at start, updated per state change | `state` (`recording`, `recorded`, `processing`, `done`, `failed`), start time, duration, `systemAudio` (bool), notes file path, failure reason |
| `mic.pcm`, `system.pcm` | During recording | Headerless 16 kHz mono Int16 little-endian. Crash-safe: every byte written is readable, unlike `.m4a`, whose index is written only on a clean close. About 115 MB per track-hour. |
| `transcript.json` | After merge | The merged `[MeetingUtterance]`, so Regenerate Notes reruns only the LLM step |
| `mic.m4a`, `system.m4a` | After the pipeline finishes | AAC transcodes of the `.pcm` files (which are then deleted), about 25 MB per track-hour |

Notes go to `<notes folder>/<yyyy-MM-dd HHmm> <title>.md`. The notes folder
defaults to `~/Documents/voxline Meetings` and is created on first use. Titles
are sanitized (`/`, `:` and control characters replaced, trimmed to 80
characters); an existing name gets ` (2)`, ` (3)`… The title comes from the LLM;
it is "Meeting" when notes were not generated.

Retention deletes the whole meeting directory after the configured period. The
Markdown file is the permanent record and is never touched by retention.

## Lifecycle

**Start** (menu or shortcut):

1. Mic permission is already granted for dictation; if it is not, show the
   existing permission guidance and do not start.
2. The first time ever, show a one-time notice: many places require telling
   participants they are being recorded. voxline never announces anything into
   the call.
3. Create the system tap. On first use macOS shows the System Audio Recording
   prompt. If denied or creation fails, record mic-only and show a one-time
   notice that remote speakers will not be separated. In mic-only mode the mic
   track is labeled "Speaker" (no Me/Them split) and diarization runs on the mic
   track instead, so in-person meetings still get Speaker 1…N.
4. Write `meta.json` (`recording`), start both tracks, switch the menu-bar icon,
   show the chip.

**During:**

- 55:00: notification "Meeting recording stops in 5 minutes." 60:00: automatic
  stop, identical to a manual stop.
- Device change or a track's engine failure: `MeetingRecorder` restarts that
  track and keeps appending to the same file, inserting silence for the gap so
  the two tracks stay time-aligned. If a restart fails three times in a row,
  the recording stops and processes what exists.
- Disk write failure (e.g. disk full): stop and process what was written.

**Stop:** `meta.json` → `recorded`, chip and icon revert, `MeetingPipeline`
starts in the background.

**Processing** (`meta.json` → `processing`):

1. Transcribe `mic.pcm`, then `system.pcm`, sequentially. A track whose peak
   level never crosses the existing silence threshold is skipped.
2. Diarize the system track (or the mic track in mic-only mode). The whole
   track is loaded as Float32 for SpeakerKit, about 230 MB for an hour.
3. Merge.
4. Write `transcript.json`.
5. Notes request.
6. Write the Markdown file, transcode audio to `.m4a`, `meta.json` → `done`,
   post a "Meeting notes ready" notification whose click opens the file.

**Quit during recording or processing** asks for confirmation. After a quit or
crash, launch-time `MeetingStore` discovery finds directories in `recording`,
`recorded` or `processing` and posts "Process unfinished meeting from 2:04 PM?";
accepting runs the pipeline from the start on the existing `.pcm` files.

## Echo suppression

On speakers, the mic also hears remote participants, which would put their
words in the transcript twice, once as "Me". `TranscriptMerger` drops a mic
segment when it overlaps a system segment in time (with 1.5 s tolerance either
side) and at least 60% of its normalized words appear in that system segment.
Headphones avoid the problem entirely; the README says so.

## Notes

Prompt inputs: the merged transcript as `[hh:mm:ss] Speaker: text` lines, the
meeting date and duration, and the custom vocabulary list (so names are spelled
as the user spells them).

Structured result (JSON schema via the existing `StructuredOutputSupport`
path for both providers):

```
title: string
summary: string            // 3–5 sentences
keyPoints: [string]
decisions: [string]
actionItems: [{ owner: string, task: string, due: string? }]
openQuestions: [string]
speakerNames: { "Speaker 1": "Priya", ... }   // only names stated in the conversation
```

Prompt rules: use speaker labels exactly as given; only fill `speakerNames`
from names stated in the conversation, never guessed; owners are speaker
labels; no invented dates.

Request: the resolved notes model, output budget 8,192 plus the existing
`thinkingHeadroom`, request timeout 180 s. An hour of speech is about 15k
input tokens.

Rendered file:

```markdown
# Q4 pricing review with Acme
2026-10-09 · 14:02–14:48 (46 min) · Me, Speaker 1, Speaker 2 (Priya)

## Summary
…

## Key points
- …

## Decisions
- …

## Action items
- [ ] **Me** — send revised quote — due Friday
- [ ] **Speaker 2 (Priya)** — confirm seat count

## Open questions
- …

---

## Transcript

**Me** [00:00:12] Thanks for joining…
**Speaker 1** [00:00:31] …
```

Inferred names are shown as `Speaker 2 (Priya)`, never replacing the label.
Empty sections read "None recorded."

## Failure handling

The Markdown file is written whenever any transcript exists.

| Failure | Result |
|---|---|
| No API key, LLM error, refusal, truncation, or unparseable result | File contains header and transcript, with a note under the title: "Notes not generated: <reason>. Use Regenerate Notes in the menu." Title "Meeting". |
| Diarization fails or its model cannot be downloaded | Diarized track labeled "Them" (mic-only mode: "Speaker"). File notes it. |
| One track's transcription fails | Uses the other track; the file states which track is missing. |
| Both tracks silent or empty | No file. Notification "Nothing was recorded." Meeting directory deleted. |
| Both transcriptions fail | No file; `meta.json` → `failed` with reason; notification offers Retry, which reruns the pipeline. |

Model downloads: SpeakerKit models (about 30 MB) and, if the user has never used
the Whisper engine, the Whisper model download on first meeting processing,
with progress in the menu status line. Offline with no models: fails as above
with the reason "model download needed".

## Regenerate Notes

Menu → Regenerate Notes › lists up to 10 most recent meetings that still have a
`transcript.json` (date and title). Choosing one reruns only the notes step
with the current notes model and writes a new file with ` (regenerated)`
appended, never overwriting a file the user may have edited.

## Settings → Meetings

- Notes folder (folder picker; default `~/Documents/voxline Meetings`)
- Start/stop shortcut (`KeyComboRecorderView`; unset by default; validated by
  `KeyComboValidator` against the dictation and command chords)
- Meeting notes model (text field; placeholder shows the fallback model)
- Keep meeting audio: Don't keep / 7 days / 14 days (default) / 30 days / Forever
- Show recording timer (default on)

## Privacy

Audio stays on the Mac and is deleted per the retention setting. The merged
transcript and the custom vocabulary are sent to the user's LLM provider for
notes. The README Privacy section gains a paragraph covering this and the
consent reminder.

## Metrics

Log per meeting through `AppLog`: duration, systemAudio, per-stage
milliseconds (transcribe mic, transcribe system, diarize, merge, notes),
speaker count, transcript token estimate, notes outcome. No transcript text in
logs.

## Testing

Unit tests, following the repo's existing patterns and fakes:

- `TranscriptMerger`: interleaving by start time, joining same-speaker runs
  under the gap threshold, echo suppression at and around the 60% / 1.5 s
  thresholds, mic-only labeling, an empty track.
- `MeetingNotesWriter`: prompt assembly, schema parsing, Markdown rendering
  including inferred names and "None recorded", the notes-failed fallback file.
- `MeetingPipeline` with fake transcriber, diarizer and LLM: every row of the
  failure table, stage publishing, `meta.json` transitions.
- `MeetingRecorder` with `ManualClock`: 55:00 warning and 60:00 stop, track
  restart with silence padding, stop after three failed restarts, stop on
  write failure.
- `MeetingStore`: file-name sanitizing and collisions, retention per setting,
  unfinished-meeting discovery per state, regenerate list.
- Integration (skipped in CI without models, like the bake-off): a short
  two-voice fixture through real WhisperKit + SpeakerKit yields two speakers
  and correctly ordered utterances.

Manual (`docs/release/MANUAL_TESTS.md`, new Meetings section): first-run System
Audio Recording prompt and denial → mic-only; a call with two or more remote
speakers; speakers vs headphones (echo); the 55/60-minute marks via a debug
override of the cap; switching input device and output device mid-meeting;
killing voxline mid-recording and mid-processing, then recovery; dictating
during a meeting; no API key; offline first run.

## Done when

- A 45-minute video call with two remote participants produces, within the
  spike-measured time, a Markdown file with notes, three distinct speaker labels
  (Me plus two), and action items attributed to the right labels.
- An in-person meeting recorded mic-only produces Speaker 1…N notes.
- Killing voxline at minute 20 and relaunching recovers and processes the
  first 20 minutes.
- Dictation behaves exactly as in 0.6.0 during and outside meetings.
- No meeting audio exists on disk after the retention period.

## Out of scope

Live transcript during the meeting, automatic meeting detection or prompts,
editable or multiple note templates, an in-app meetings browser, naming or
enrolling speakers by voice, cloud transcription or diarization for meetings,
meetings longer than 60 minutes, calendar integration, follow-up email drafts.
Live transcript (Approach 2 in brainstorming) can be layered on later without
changing the post-stop pipeline.

## Spike results (2026-10-09)

Machine: Apple M3 Pro, 36 GB RAM. Audio: synthetic two-voice fixture tiled to 60 min.

| Model | Transcribe | Diarize + align | Total after load | Peak footprint |
|---|---|---|---|---|
| large-v3 turbo | 237.7 s | 32.3 s | 269.9 s | 1439 MB |
| small.en | 207.5 s | 32.3 s | 239.8 s | 1350 MB |

Both rows are second runs (the first includes Core ML compilation). large-v3 turbo misses the 240 s total target; small.en meets both targets, with only 0.2 s of margin on time.

Cold-run model load (first run, includes Core ML compilation): small.en about 89 s, large-v3 turbo about 148 s.

WER on bake-off-style clips (WhisperKit, one-shot per clip, no dictionary or cleanup): the real bake-off clips were not on this machine (no `bakeoff` folder in the app container or Application Support), so this uses 12 synthetic `say` clips (5 jargon terms, 152 reference words, via `scripts/make-synthetic-bakeoff.sh`). large-v3 turbo 12.50% WER (19/152), 3/5 terms; small.en 10.53% WER (16/152), 4/5 terms. No measurable accuracy loss from small.en on this set; it has not been checked on real recordings.

Decision: meetings use small.en. This is provisional: the time margin is effectively zero (239.8 s against a 240 s target) and the audio is synthetic, so it must be re-checked on real audio (and a real-clip WER comparison) before relying on it.
