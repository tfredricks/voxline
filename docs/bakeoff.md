# Engine bake-off

The bake-off runs each speech engine over the same recordings and picks the
default by a rule written down before any run (the "Decision rule" in
`docs/superpowers/specs/2026-10-08-transcription-engine-design.md`). It measures
word error rate (WER), dictionary-term misses, and how long each engine takes
after the last audio arrives. A synthetic text-to-speech run set the
provisional default; your own recordings are the real test.

## 1. Capture real clips

Turn the capture flag on. Use the path form of the domain: a bare
`com.voxline.app` can resolve to a leftover sandbox container's plist.

```bash
defaults write ~/Library/Preferences/com.voxline.app voxline.debug.saveBakeoffClips -bool YES
```

Quit and relaunch voxline, then dictate as you normally do: 20 or more clips of
3 to 30 seconds, with the names and jargon you actually say. Each successful
dictation writes `<timestamp>.wav` (16 kHz mono) and `<timestamp>.txt` to
`~/Library/Application Support/voxline/bakeoff/`. Nothing else in voxline writes
audio to disk.

## 2. Correct the references

Each `.txt` starts as voxline's cleaned text, only a draft. Rewrite it as
exactly what you said, word for word; capitalization and punctuation are
ignored. Delete both files of any clip you don't want scored.

## 3. Write terms.txt

Put a `terms.txt` in the same folder: one dictionary term per line, spelled the
way you want it (`LangGraph`, `Fredricks`). Matching ignores case, spaces, and
punctuation ("lang graph" counts as "LangGraph", since cleanup repairs that),
and only terms that appear in your references are counted.

## 4. Run it

```bash
TEST_RUNNER_VOXLINE_BAKEOFF=1 xcodebuild test \
  -project voxline.xcodeproj \
  -scheme voxline \
  -destination 'platform=macOS' \
  -only-testing:voxlineTests/EngineBakeoffTests
```

Clips play in real time, one engine after another, so expect about the total
audio length per engine. Whisper large-v3 turbo runs only if it is already
downloaded. Optional variables, each with the `TEST_RUNNER_` prefix:
`VOXLINE_BAKEOFF_DIR=<dir>` reads clips from another folder;
`VOXLINE_BAKEOFF_CLOUD=1` adds OpenAI (it sends the clips to OpenAI with your
saved key, is reported, and can never win).

## 5. Read the verdict

The report prints to the terminal and is saved as `bakeoff-report.md` next to
the clips: one row per engine with WER, term miss rate, finish latency (median
and p90), and time to the first live text, then the verdict from the rule:

1. Only on-device engines can win.
2. An engine more than 5 WER points worse than the best is out.
3. If the two lowest term miss rates are within 2 points, lower median finish
   latency wins.
4. Otherwise the lowest miss rate wins, unless its median finish latency is
   more than 300 ms worse than the runner-up's; then the runner-up wins.

If the verdict is not the current default, change `EngineID.default` in
`voxline/Transcription/TranscriptionEngine.swift` in a separate commit.

## 6. Clean up

```bash
defaults delete ~/Library/Preferences/com.voxline.app voxline.debug.saveBakeoffClips
rm -r ~/Library/Application\ Support/voxline/bakeoff
```

Quit and relaunch voxline. Never commit the clips: they are your voice and
your text. `scripts/make-synthetic-bakeoff.sh lines.txt outdir` renders TTS
clips for smoke runs (set `TEST_RUNNER_VOXLINE_BAKEOFF_DIR` to `outdir`).
