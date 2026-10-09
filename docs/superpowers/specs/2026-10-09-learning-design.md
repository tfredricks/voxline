# Phase 5 — Learning

**Date:** 2026-10-09
**Status:** Design for review. The maintainer's rulings are recorded as
decisions. The other choices give their reason, so any of them can be
overturned in review.
**Roadmap:** Phase 5 of `2026-10-08-voxline-roadmap-design.md`.
**Builds on:** this spec is written against `main` at `1ef7331`, after phases
1–4. Phase 3's AX seam (`AXTextElement`, `AXRead`, `UTF16Range`,
`LiveFocusedElementSource`), its insert path (`TextInserter`,
`InsertionPlan`), and phase 2's `SessionConfig.vocabularyHints` are used as
they exist there.

## Goal

Stop correcting the same word twice, and make dictated text sound like the
user without anyone editing per-app prompts. After a dictation lands, voxline
checks once whether the user changed it. A fixed name joins the custom
vocabulary, which already feeds the engine hints and the cleanup prompt.
Larger edits, together with the user's recent dictations, become a short style
note for each mode category.

## What exists today (verified)

- **Insert.** `CapturePipeline.performDictation` calls
  `inserter.insert(cleaned, at: .liveSelection, expectedElement: nil, …)`.
  `InsertOutcome.inserted(strategy, verified:)` does not report where the
  text landed or which element it went into. AX writes land synchronously
  (`AXTextEditor.replaceSelection`). A paste lands when the target app reads
  the promised pasteboard type, and that has usually happened by the time
  `insert` returns.
- **AX reads.** `LiveFocusedElementSource.readElement()` is one AX call.
  `AXTextElement.string/range` return a tri-state `AXRead`. Every element has
  a 0.5 s messaging timeout (`AXMessagingTimeout`). `EditContextPolicy.default`
  marks VS Code and Cursor as apps whose `kAXValue` is a hidden input, not
  the document. Electron apps usually have no readable `kAXValue`, because
  voxline never sets `AXManualAccessibility`.
- **Vocabulary.** `CustomVocabularyStore` is a plain `[String]` under
  `voxline.context.customVocabulary` in UserDefaults. It is read at recording
  start in two places: `SessionConfig(vocabularyHints:)` in `startRecording`,
  and `CapturedContext.customVocabulary` in `ContextCaptureService.capture`.
  Apple Speech maps the hints to `contextualStrings`, OpenAI Realtime puts
  them in its prompt, and WhisperKit ignores them. Meetings read the same
  store. The Settings list (`CustomVocabularyListView`) has rows with a
  remove button, an Add field, and no source column.
- **Issue 15.** `GeneralSettingsViewModel.resetToDefaults()` calls
  `vocabulary.save([])`, and the Reset button in `SettingsView` has no
  confirmation.
- **Modes.** `ModeCategory` is `chat`, `email`, `writing`, `code`, or
  `general`. Unknown apps resolve to the `*` mode, whose category is
  `general`. Issue 19 is done: `Mode` decoding already tolerates missing
  fields.
- **Cleanup prompt.** `LLMService.systemPrompt(mode:context:)` builds the
  system prompt from `preambleCore`, plus `contextParagraph` and
  `vocabularyParagraph` when they apply, plus `styleHeader` and `mode.prompt`.
  `ContextBlockFormatter` builds the user message. Surrounding text (200
  characters before the cursor, 100 after) is already sent and already
  covers the roadmap's "surrounding text" item.
- **Toasts.** `AppState.flashToast(_:for:)` sets a plain `toastMessage`. The
  pill panel ignores the mouse except while it offers Retry
  (`RecordingPillWindow.updateVisibility`). No toast can carry an action.
- **History** keeps 25 items in total, which is too few to supply 20
  dictations per category. **AppLog** has no `learning` category.

## Decisions

| Question | Decision | Why |
|---|---|---|
| How corrections are seen | **Snapshot, not notifications.** After a dictation insert, remember the element, the inserted text, its `UTF16Range`, and 32 units of text on each side. Each poll tick re-reads the value and keeps the **last snapshot whose region was located and changed**. At window end, read the value once more; if that read can't locate the region (field sent or cleared, element gone, region ambiguous), use the last such snapshot. One diff per window. `kAXValueChangedNotification` is not used. | Ruling 1, amended: a fix followed by sending in Messages or a Mail compose must still be learned. Reads work in any app whose value is readable, Electron included, with no observer plumbing. |
| Window length (deferred question) | **30 s**, or until focus leaves the element, or until a new dictation, command, preset, or retry starts, whichever comes first. | Ruling 1. |
| Poll | Once a second, off the main actor: `LiveFocusedElementSource.readElement()`, then `kAXValue` of the anchored element, then `RegionLocator` on it. A different focused element, or `.absent`, ends the window. `.failed` does not. | An `AXObserver` needs a run-loop thread and per-app registration calls that can block. Cost: ≤ 30 focus reads and ≤ 31 value reads per window (30 ticks plus the final read), each detached and bounded by the 0.5 s messaging timeout. |
| Last good snapshot | A tick whose locate result is `.changed` replaces the stored snapshot. `.unchanged`, `.discarded`, `.ambiguous`, and failed reads leave it alone. The final read wins when it is `.changed` or `.unchanged`. Otherwise, if a snapshot is stored, it is diffed instead; if not, the final result stands. | Still never a guess: every snapshot was located by the same unique-prefix and bounds rules. Keeping only `.changed` snapshots means deleting an unedited dictation is still `.discarded`, and an edit that the user then reverts counts as reverted. |
| When learning skips | Skip silently and log a reason with counts only when: Accessibility isn't trusted; there is no focused element; the field is secure or its subrole can't be read; the value can't be read; the app is a terminal (`InsertionPlan.isTerminal`) or in `EditContextPolicy.untrustedFieldBundleIDs`; the inserted text doesn't sit right before the caret; or the region can't be found unambiguously at window end. | Ruling 1: never guess. Terminal values are scrollback, and VS Code and Cursor expose a hidden input, not the document. |
| Vocabulary candidate | A hunk is a candidate only if all of these hold: (1) each side has 1–2 word tokens; (2) the change is not case-only and not punctuation-only; (3) the sides are **close** (see Similarity); (4) there is a **signal**: a new word has a digit or an internal capital, or a new word is unknown to `NSSpellChecker`, or the new side is capitalized mid-sentence where the old side started lowercase; (5) the region is not a heavy rewrite. | Ruling 2. Clause (4) keeps the ruling's three signals. The capital counts only when the user added it, so "Tuesday" → "Thursday" (both dictionary words, both already capitalized) stays out, while "clod" → "Claude" gets in. |
| Similarity (deferred question) | Normalize both sides: lowercase, letters and digits only, spaces dropped. `d = levenshtein(a, b) / max(|a|, |b|)`. Close when **`d ≤ 0.34`**, or when **`d ≤ 0.6` and the phonetic keys are equal** (key length ≥ 2). | Ruling 2. Dropping spaces makes segmentation fixes ("arg max" → "Argmax") distance 0. The phonetic key catches sound-alike misspellings with a large edit distance ("Cooper Nettis" → "Kubernetes": d = 0.5, keys `216532` and `216532`). |
| Phonetic key | Soundex digit classes without truncation, applied to every letter including the first. Drop vowels and `h w y`, map `bfpv→1`, `cgjkqsxz→2`, `dt→3`, `l→4`, `mn→5`, `r→6`, keep digits, collapse runs of the same code. | Pure, about 20 lines, and testable. Coding the first letter lets c/k and s/z match. |
| Heavy rewrite | When more than 2 word tokens changed **and** they exceed 50% of the inserted word tokens, every hunk is a style signal and none is a vocabulary candidate. | A substitution inside a rewritten sentence is a rewording, not a misheard word. The floor of 2 keeps a one- or two-word fix in a short dictation ("ask Cooper Nettis") from counting as a rewrite. |
| Discarded insert | A region shorter than 25% of the inserted text (an undo, or the user deleting the dictation) records nothing: no word, no style pair, no final text. | It says the dictation was unwanted, not how the user writes. |
| Auto-add | Add the word, then toast "Learned: Argmax" with **Undo** for 5 s. A word already in the vocabulary (case-insensitive) is not added again. | Ruling 3. |
| Toast action | `AppState` gains an optional `toastAction`, set by `flashToast(_:for:action:)` and cleared together with the message. The pill takes clicks while a toast has an action, and the button reuses Retry's capsule. | Ruling 3. This is the smallest addition: one property and one button, and the panel already becomes clickable for Retry. |
| A toast while voxline is busy | A "Learned" toast waits until `state.status` is `.idle`, then shows. One that has waited 60 s is dropped; the word stays learned. | The most common window end is the start of the next dictation, when the recording pill would hide the toast. |
| Rejected words | Undo, removing a learned word in Settings, or Clear All on a list that holds learned words adds them to a rejected list (case-insensitive, newest 200). A rejected word is never learned again. Adding it by hand takes it off the list. | Ruling 3. |
| Vocabulary source | The terms stay a `[String]` under the existing key, and `load()` is unchanged. A sidecar `[String]` under `voxline.context.learnedVocabulary` names the learned terms. Any term not in the sidecar is `user`. | Ruling 4. Old data loads as it is, with nothing to migrate and no change for the three readers of `load()`. |
| Style refresh (deferred question) | **N = 20** final texts recorded in a category since the last refresh. | Ruling 5. |
| Style refresh inputs | The current note (≤ 600 characters); up to the 20 newest final texts in the category, each ≤ 600 characters, 8,000 in total (oldest dropped first); and up to the 10 newest style pairs, each side ≤ 500 characters, 6,000 in total. | Ruling 5. A few thousand input tokens, once per 20 dictations. |
| Style note | At most 600 characters, asked for as 3–6 short lines under 80 words. A longer reply is cut at the last line break before 600. The model is told never to quote, name, or repeat facts from the texts. | Ruling 5. It keeps the per-dictation cost bounded and keeps content out of the note. |
| Prompt additions | The category's note, plus up to **2** final texts from the same bundle ID (newest first, ≥ 20 characters each), each cut to **400** characters at a word boundary with "…". Together that is ≤ 1,400 characters of content. | Ruling 5. Texts under 20 characters ("ok", "thanks!") carry no voice. |
| Edited notes | Editing a note marks it `editedByUser`. Automatic refreshes then skip that category. A **Regenerate** button replaces the note after a confirmation and clears the flag. | Ruling 5: an edit is never silently overwritten. |
| Refresh failure | Keep the old note, reset the counter to 0, and log the error type. | One retry per 20 dictations; a missing key doesn't retry on every dictation. |
| Refresh model | The cleanup model (`AppSettings.llmModel`), plain text, `maxOutputTokens` 400. | Summarizing habits is a small task. A setting would be scope creep. |
| Settings | A new **Learning** section with two toggles (both default on), the per-category notes, and "Reset Learning…" with confirmation. | Ruling 6. |
| Both toggles off | No observation window opens, no anchor read happens, nothing is recorded, and the system prompt is identical to today's. Learned words already in the vocabulary stay: by then they are vocabulary. | Ruling 6. |
| Toggling off mid-window | The toggles are read again when the window ends. With both off, the window is cancelled with no final read. | "Off" takes effect at once. |
| Data kept when style learning is off | Collection and prompt use stop; stored texts, pairs, and notes stay until Reset Learning. | Turning it back on picks up where it left off. Reset is the delete control, and Settings says so. |
| Issue 15 | `resetToDefaults()` no longer touches the vocabulary. The vocabulary list gains "Clear All…" with a confirmation. | Ruling 7. |
| Reset to Defaults and Learning | Reset to Defaults changes neither the Learning toggles nor learned data. | Same reasoning as for presets and the vocabulary: Reset is for pipeline settings. Quietly turning field observation back on would surprise a user who had turned it off. |
| Reset Learning | Deletes `learning.json` (notes, texts, pairs, counters, rejected list) and removes the learned-source words from the vocabulary. Words the user added stay. | The user can't tell learned words apart once they act the same, so a reset that keeps them resets nothing visible. |
| Clear History | Leaves learning data alone. | History and Learning have separate controls, and the README says where each kind of data lives. |
| Storage | `~/Library/Application Support/voxline/learning.json` through `AppPaths.learningFile()`. Every field is `decodeIfPresent`, and unknown category keys are dropped. A file that fails to decode is renamed `learning.corrupt.json`, and learning starts empty. | Ruling 8. Tolerant decoding means a future field never wipes the notes. |
| What is learned from | Dictation inserts, including Retry, only. Commands and presets are not observed, but they do close an open window. | Ruling 9. A command's insert goes through `EditPlanner`'s targets, some of them a rewrite hunk or a live selection, and its text is the model's answer, not the user's dictation. Observing it is not the same path, so it is a non-goal. |
| Vocabulary at cleanup | `performDictation` re-reads the vocabulary into `context.customVocabulary` just before the cleanup call. | A window that ends when the next dictation starts learns the word after that dictation's hints were taken. The fresh read still gets the word to its cleanup, which snaps phonetically close forms to it. One UserDefaults read. |
| How style reaches the prompt | `CapturedContext` gains `learnedStyle: LearnedStyle?`. The pipeline sets it before cleanup, and `systemPrompt(mode:context:)` renders it. | No change to `LLMServing`. The vocabulary already reaches the system prompt the same way. |
| Latency budget | Dictation `totalMs` median with style learning on stays ≤ 5% above the median with both toggles off (20 Slack dictations each). Anchor reads run after `resetIdle()` and are never inside `totalMs`. | The roadmap rule says each phase states a regression margin. The only per-dictation cost is ≤ ~1,700 more prompt characters. |

## Components

New folder `voxline/Learning/`. The pure pieces have no AX, AppKit, or
UserDefaults dependencies.

| File | Type | Role |
|---|---|---|
| `LearningCoordinator.swift` | `@MainActor @Observable final class LearningCoordinator` | The one entry point. `didInsert(_:)`, `captureWillStart()`, `style(for:bundleID:)`, `undo(_:)`, `regenerate(_:)`, `reset()`. Owns at most one `CorrectionWindow`, the pending announcement, the in-flight refreshes, and `vocabularyRevision` (bumped on every vocabulary change it makes, so Settings reloads). |
| `CorrectionWindow.swift` | `@MainActor final class CorrectionWindow` | One observation: anchor read, 1 Hz poll (focus plus value plus locate), last good snapshot, 30 s deadline, final read. Reports a `WindowEnd` once. |
| `CorrectionReader.swift` | `protocol CorrectionReading: Sendable`, `struct LiveCorrectionReader` | The AX seam: `anchor(for:) -> AnchorRead`, `focusedRef() -> AXRead<AXElementRef>`, `value(of:) -> AXRead<String>`. Synchronous; callers run it detached. |
| `InsertAnchor.swift` | `struct InsertAnchor`, `static func make(value:caret:inserted:)` | Pure. Builds the anchor from a value and a caret, or returns nil. |
| `RegionLocator.swift` | `enum RegionLocator` | Pure. `locate(_ anchor: InsertAnchor, in value: String) -> RegionMatch`. |
| `WordTokenizer.swift` | `enum WordTokenizer`, `struct Token` | Pure. Splits text into word, whitespace, and punctuation tokens. |
| `TokenDiff.swift` | `enum TokenDiff`, `struct Hunk` | Pure. LCS over non-whitespace tokens, returning hunks of (old tokens, new tokens) with their token indices. |
| `Similarity.swift` | `enum Similarity` | Pure. `normalized`, `levenshtein`, `phoneticKey`, `isClose`. |
| `CorrectionClassifier.swift` | `enum CorrectionClassifier`, `protocol WordDictionary` | Pure given a `WordDictionary`. Returns `Classification { vocabulary: [String], isStyleSignal: Bool, changedWordCount }`. |
| `SpellCheckDictionary.swift` | `@MainActor struct SpellCheckDictionary: WordDictionary` | The `NSSpellChecker.shared` adapter, used on the main actor (`NSSpellChecker` is not thread-safe). |
| `LearningStore.swift` | `@MainActor final class LearningStore`, `struct LearningData` | Loads and saves `learning.json`, enforces the caps, and counts toward refreshes. |
| `StyleNotePrompt.swift` | `enum StyleNotePrompt`, `struct StyleNoteRequest` | Pure. Builds the refresh prompt and applies the input caps. |
| `LearnedStyle.swift` | `struct LearnedStyle`, `enum LearnedStyleFormatter` | Pure. What rides on `CapturedContext`, and its system-prompt paragraph. |

Changed:

| File | Change |
|---|---|
| `Storage/CustomVocabularyStore.swift` | `VocabularySource { user, learned }`, `VocabularyEntry`, `entries()`, `addLearned(_:) -> Bool`, `remove(_:) -> VocabularyEntry?`, `removeAll() -> [VocabularyEntry]`, `removeLearned() -> [String]`. `save(_:)` prunes the sidecar to the surviving terms. `load()` and `parse(_:)` are unchanged. |
| `Storage/AppPaths.swift` | `learningFile()` and `learningFile(inAppDirectory:)`. |
| `Storage/AppSettings.swift` | `learnWords` (`voxline.learning.words`) and `learnStyle` (`voxline.learning.style`). An absent value reads as `true`. |
| `Context/CapturedContext.swift` | `var learnedStyle: LearnedStyle? = nil`, which is `nil` in `.empty`. |
| `LLM/LLMService.swift` | `systemPrompt(mode:context:)` appends `LearnedStyleFormatter.paragraph(_:)` after the mode prompt when `context.learnedStyle` is non-nil. New `styleNote(_ request: StyleNoteRequest) async throws -> String` behind `protocol StyleNoteGenerating: Sendable`. |
| `Pipeline/CapturePipeline.swift` | New `learning: LearningObserving?` (a protocol that `LearningCoordinator` conforms to; nil in tests that don't use it). Calls `captureWillStart()` in `startRecording` once the re-entry guard passes, and in `beginRun()` (retry and presets). In `performDictation`, refreshes `context.customVocabulary`, sets `context.learnedStyle`, and after `.inserted` and `resetIdle()` calls `didInsert(InsertedDictation(text:bundleID:category:))`. |
| `AppState.swift` | `toastAction: ToastAction?` (`title`, `perform: @MainActor () -> Void`), and `flashToast(_:for:action:)`. Any later `flashToast` replaces both. |
| `UI/RecordingPillView.swift`, `UI/RecordingPillWindow.swift` | The toast shows the action button. The panel takes clicks while `content == .toast && toastAction != nil`, and the width adds `retrySpacing + retryButtonWidth`. Retry's capsule becomes a shared `PillActionButton`. |
| `Settings/Components/CustomVocabularyListView(Model).swift` | Rows read `entries` and show a secondary "Learned" label. Removing a learned row rejects it. "Clear All…" with a confirmation. The footer reads "N terms (M learned)". |
| `Settings/GeneralSettingsViewModel.swift`, `Settings/SettingsView.swift` | Issue 15: the `vocabulary` dependency and `save([])` go. The Reset button stops reloading the vocabulary list. `SettingsView` adds `LearningSection` after Custom vocabulary and reloads the vocabulary list when `vocabularyRevision` changes. |
| `Settings/LearningSettingsViewModel.swift`, `Settings/Components/LearningSection.swift` | New; see Settings. |
| `Diagnostics/AppLog.swift` | `static let learning`. |
| `AppCoordinator.swift` | Builds `LearningStore` and `LearningCoordinator` and hands the coordinator to the pipeline and to Settings. |

## Data model

```swift
// UserDefaults (unchanged key + one sidecar key)
voxline.context.customVocabulary   [String]   // all terms, display order
voxline.context.learnedVocabulary  [String]   // subset that was learned
voxline.learning.words             Bool       // absent → true
voxline.learning.style             Bool       // absent → true

// ~/Library/Application Support/voxline/learning.json
struct LearningData: Codable {
    var version: Int = 1
    var categories: [String: CategoryLearning]   // ModeCategory.rawValue; unknown keys dropped
    var rejectedWords: [String]                  // newest last, max 200
}
struct CategoryLearning: Codable {
    var note: String?                // nil until the first refresh
    var noteEditedByUser: Bool
    var noteUpdatedAt: Date?
    var recentTexts: [FinalText]     // newest last, max 20, text ≤ 600 chars
    var stylePairs: [StylePair]      // newest last, max 10, each side ≤ 500 chars
    var sinceRefresh: Int
}
struct FinalText: Codable { var text: String; var bundleID: String?; var date: Date }
struct StylePair: Codable { var before: String; var after: String; var date: Date }
```

Every property decodes with `decodeIfPresent` and a default. Caps are applied
on write. A final text over 600 characters is stored as its first 600,
snapped to a composed-character boundary. A style pair is recorded only when
both sides are ≤ 500 characters, because cutting each side separately would
misalign them. The worst case is about 5 × (12 KB + 10 KB) ≈ 110 KB, written
atomically on the main actor once per dictation.

## Correction observation lifecycle

```
performDictation ── .inserted ── resetIdle() ── learning.didInsert(text, bundleID, category)
                                                   │ toggles both off → return
                                                   │ terminal / untrusted app → log skip, record final text, return
                                                   ▼
                                   CorrectionWindow.start (token t)
                                   detached: reader.anchor(for: text) ──► nil → record final text (inserted), end
                                                   │ (retry once after 300 ms if not found)
                                                   ▼
                       every 1 s, detached: reader.focusedRef() ≠ anchor.ref → end(.focusLeft)
                                            reader.value(of: anchor.element) → RegionLocator
                                            .changed → lastGood = region text
                       30 s deadline ─────────────────────────────────────────► end(.timeout)
                       captureWillStart() (dictation, command, preset, retry) ─► end(.newCapture)
                                                   ▼
                                   detached: reader.value(of: anchor.element)
                                   RegionLocator → (.changed/.unchanged ? final : lastGood ?? final)
                                   main: CorrectionClassifier (once) → apply
```

**Anchor read** (`LiveCorrectionReader.anchor(for:)`, detached):

1. If `AXIsProcessTrusted()` is false, skip with `notTrusted`.
2. `LiveFocusedElementSource.readElement()` must give a value, else skip with
   `noElement`.
3. Read the subrole. `.failed` skips with `notResponding`, and the secure
   subrole skips with `secure` (fail closed, as `EditContextReader` does).
4. Read `kAXValue` and `kAXSelectedTextRange`. Either one unreadable skips
   with `valueUnreadable`. A range that doesn't `fits(in:)` the value skips
   too.
5. `InsertAnchor.make(value:caret:inserted:)`: the caret must have zero
   length, and the `inserted.utf16.count` units ending at the caret must
   equal `inserted`. If not, wait 300 ms and read once more (a paste can
   still be landing), then skip with `notAtCaret`.

```swift
struct InsertAnchor: Sendable {
    let element: any AXTextElement      // + its AXElementRef
    let inserted: String
    let range: UTF16Range               // where it landed
    let prefix: String                  // ≤ 32 units before, start snapped outward to a composed boundary
    let suffix: String                  // ≤ 32 units after, end snapped outward
}
```

**Ending.** The window ends once, for the first of `.timeout`,
`.focusLeft`, or `.newCapture`. A poll that returns `.failed` keeps the
window open. Every detached result carries the window token `t`. The
coordinator drops a result whose token is not current, so a late anchor read
can never revive a window that a new capture closed. `captureWillStart()`
only starts the final read; it never waits for it, so recording starts as
fast as it does today. The final read happens before the new dictation's text
can reach the field, because that takes at least the recording plus cleanup.

**Region** (`RegionLocator.locate`, pure; run on every tick's value and on
the final value):

1. `value(of: anchor.element)` reads the stored element, not the focused
   one, so a Mail draft behind another window still reads. `.failed` or
   `.absent` is `valueUnreadable`.
2. Region start: an empty `prefix` means 0. Otherwise `prefix` must occur
   exactly once in the value, and the region starts right after it. Zero
   occurrences or more than one returns `.ambiguous`.
3. Region end: an empty `suffix` means the end of the value. Otherwise use
   the first occurrence of `suffix` at or after the start; none returns
   `.ambiguous`.
4. Bounds: a region longer than `max(2 × inserted, inserted + 200)` units
   returns `.ambiguous`. One shorter than 25% of `inserted` returns
   `.discarded`. Text equal to `inserted` returns `.unchanged`. Anything else
   returns `.changed(text)`.

**Choosing what to diff** (`CorrectionWindow.resolve(final:lastGood:)`,
pure). A final `.changed` or `.unchanged` is used as it is. Any other final
result (`.ambiguous`, `.discarded`, `valueUnreadable`) is replaced by
`.changed(lastGood)` when a last good snapshot exists, and stands otherwise.
So "fix the name, press Return" in Messages diffs the fixed text from the
last tick before the send.

The resolved result decides what is recorded. `.ambiguous` and
`valueUnreadable` record the inserted text as the final text, and nothing
else. `.discarded` records nothing. `.unchanged` records the inserted text as
the final text. `.changed` runs the classifier once, and the region's text
becomes the final text.

What is still missed: a fix and a send both made within the first second
(before any tick), and anything in apps whose value is unreadable.

**Concurrency.** The coordinator, the window, the store, and the classifier
run on the main actor. Every AX call (anchor, poll, final read) runs in
`Task.detached(priority: .utility)` through `CorrectionReading`, and each one
is bounded by the 0.5 s messaging timeout. `RegionLocator` runs inside the
same detached task as the read it checks, so the main actor only ever sees a
locate result and at most one region string. A tick never overlaps the next:
the poll loop awaits each tick before sleeping again. The poll and the deadline sleep
through an injected `sleep` (tests use `ManualClock`). There is one window
at a time: `didInsert` ends any open window with `.newCapture` first, which
can't normally happen because `captureWillStart` already ran.

**Logging.** Each window logs one line to `AppLog.learning`:
`window end=<timeout|focusLeft|newCapture> region=<changed|unchanged|ambiguous|discarded|unreadable> hunks=N vocab=N style=<0|1> source=<final|lastGood> ticks=N`, or, for a window that never anchored, `window end=<anchor|newCapture|none> region=skipped:<reason> hunks=0 vocab=0 style=0`.
It never logs text, terms, or lengths beyond counts.

## Classifier

**Tokens.** A word token is a run of letters, digits, and combining marks.
`'`, `’`, `.`, `-`, and `_` join a word when a letter or digit is on both
sides ("don't", "Node.js", "e-mail"). Whitespace runs are tokens and are
dropped before the diff. Every other character is a one-character
punctuation token. Tokens carry their `UTF16Range` in their source string.

**Diff.** `TokenDiff` runs an LCS over the non-whitespace tokens of
`inserted` and the region and returns the hunks. Both sides are capped at
1,000 tokens; a longer region is `.ambiguous`.

**Per hunk** (`old` and `new` word tokens; punctuation inside the hunk
travels with it):

| Test | Rule |
|---|---|
| Punctuation-only | Neither side has a word token, or the word tokens are equal → style signal. |
| Case-only | The lowercased words, joined with single spaces, are equal → style signal. |
| Size | `1 ≤ old.count ≤ 2` and `1 ≤ new.count ≤ 2`, else style signal. |
| Close | `Similarity.isClose(old.joined(), new.joined())`, else style signal. |
| Signal | A new word has a digit or an uppercase letter after its first character; or a new word is not known to the `WordDictionary`; or the first new word is capitalized and **mid-sentence** while the first old word starts lowercase. Else style signal. |
| Heavy rewrite | Total changed word tokens across all hunks (per hunk, the larger side) > 2 and > 50% of the inserted word tokens → every hunk is a style signal. |
| Term shape | The term is the region's text from the first to the last new word, with outer punctuation trimmed. It must be 2–40 characters and not only digits, else it is dropped (not a style signal either). |

**Mid-sentence** means the closest non-whitespace token before the word (in
the region, then in `anchor.prefix`) exists and is not `.`, `!`, `?`, or a
newline.

`WordDictionary.isKnown(_ word: String) -> Bool` is implemented with
`NSSpellChecker.shared.checkSpelling(of:startingAt:)`, where "no misspelled
range" means known, in the checker's current language. Words the user taught
macOS count as known.

`Classification.isStyleSignal` is true when any hunk is a style signal. The
coordinator then records `StylePair(before: inserted, after: region)`, when
style learning is on and both sides fit the cap. Vocabulary candidates are
classified the same way whatever the toggles say, so a name fix never
becomes a style pair.

**Worked cases** (all in the unit tests):

| Inserted → corrected | Result | Because |
|---|---|---|
| "ask Cooper Nettis" → "ask Kubernetes" | learn **Kubernetes** | 2→1 words, d 0.5 with equal keys, unknown word |
| "the arg max model" → "the Argmax model" | learn **Argmax** | d 0, unknown word |
| "send the Jason" → "send the JSON" | learn **JSON** | d 0.2, internal capital |
| "ping clod about it" → "ping Claude about it" | learn **Claude** | d 0.5 with equal keys (`243`), capitalized mid-sentence, old was lowercase |
| "on Tuesday" → "on Thursday" | style | both known, old already capitalized |
| "there" → "their" | style | both known, no capital |
| "slack" → "Slack" | style | case-only |
| "Thanks." → "Thanks" | style | punctuation-only |
| "we could use the new pipeline" → "use LangGraph" | style | heavy rewrite |

Then, for each candidate in order: skip it if it is already in the
vocabulary (case-insensitive) or in `rejectedWords` (case-insensitive);
otherwise, if word learning is on, `addLearned`. The words added by one
window go into one announcement: "Learned: Argmax", or "Learned: Argmax,
LangGraph", with Undo removing them all.

## Style profile

**Recording.** Each final text, when style learning is on, is appended to its
category's `recentTexts` with the bundle ID, and `sinceRefresh += 1`. When
`sinceRefresh ≥ 20`, the note is not `editedByUser`, and no refresh is
running for the category, the coordinator starts one.

**Refresh** (`StyleNotePrompt`, `LLMService.styleNote`):

- System prompt: "You describe one person's writing habits in <Category>
  messages so a dictation cleaner can match them. Write 3–6 short lines, under
  80 words in all, each a concrete habit seen in several texts: contractions,
  greetings and sign-offs, sentence length, capitalization, end punctuation,
  lists versus prose, emoji. Corrections show what the user changed after
  dictation, so weight them highly. Never quote the texts or include names,
  facts, or topics from them. Return only the lines."
- User message: the current note, if there is one; then "Texts:" numbered,
  oldest first; then "Corrections:" as `before → after` pairs. Each part
  stays within the caps in Decisions.
- Model `AppSettings.llmModel`, temperature nil, `maxOutputTokens` 400, no
  structured output. The stop and refusal checks `LLMService` already has
  apply.
- On success: trim the reply; an empty reply is a failure. Cut it to 600
  characters at the last line break. Store it with `noteUpdatedAt = now`,
  `noteEditedByUser = false`, `sinceRefresh = 0`. On failure: keep the note,
  set `sinceRefresh = 0`, and log the error type.

**Prompt assembly.** `LearningCoordinator.style(for: category, bundleID:)`
returns `nil` when style learning is off, or when there is neither a note nor
an example. Otherwise it returns
`LearnedStyle(categoryName:, note:, examples:)`, with the examples chosen as
Decisions says. `LearnedStyleFormatter.paragraph` renders it after
`mode.prompt`:

```
Learned style for Chat (from this user's own past messages; follow it where it
doesn't conflict with the rules above):
<note>

Examples of this user's own writing in this app. Match their voice; never copy
their content:
- "<example, escaped like ContextBlockFormatter>"
- "<example>"
```

Either block is left out when it is empty. With `learnedStyle == nil`, the
system prompt is byte-for-byte what `systemPrompt(mode:context:)` returns
today, and a test pins that. The fast path (`CleanupFastPath`) makes no LLM
call, so it gets no style. Commands get no style.

## Settings

**Learning** section (`LearningSection`, `LearningSettingsViewModel`), after
Custom vocabulary:

- Toggle **"Learn words from my corrections"**. Caption: "When you fix a
  dictated name or term in the field, voxline adds it to Custom vocabulary."
- Toggle **"Learn my writing style"**. Caption: "Keeps your recent
  dictations on this Mac and turns them into a short style note per kind of
  app. The note and two recent examples are sent with each cleanup."
- While style learning is on, there is one row for each `ModeCategory`. A
  `TextEditor` holds the note, and edits are saved after 1 s idle and set
  `noteEditedByUser`. A status line reads "Learned from 20 dictations ·
  updated Oct 9", or "Edited by you — automatic updates paused", or "Appears
  after 20 dictations (7 so far)". **Regenerate** is enabled once the
  category has ≥ 3 texts and asks to confirm when the note was edited.
- **"Reset Learning…"** asks: "Forget style notes, the dictations they were
  learned from, and N learned words? Words you added yourself stay." It runs
  `LearningCoordinator.reset()`.

**Custom vocabulary** gains the "Learned" label on rows, "Clear All…"
("Remove all N terms? This can't be undone."), and the footer count.

**Reset to Defaults** no longer touches the vocabulary or anything in
Learning (issue 15).

## Privacy

- Detection, classification, and storage are all local. Notes, recent texts,
  style pairs, and rejected words live in `learning.json` in Application
  Support. Learned words live in the vocabulary in preferences, as typed
  words do.
- `AppLog` gets counts and reasons only. Nothing from Learning is written to
  History. Audio is untouched.
- The style note and up to two example texts go to the user's LLM provider
  inside the cleanup prompt. A refresh sends up to 20 recent texts and 10
  correction pairs for that category. Both happen only while style learning
  is on.
- The README Privacy section gains a **Learning** bullet saying where the
  data is kept, what is sent and when, and that Reset Learning deletes it.
  The LLM-provider list gains "style note and examples" and "style refresh"
  bullets.

## Docs

- `README.md`: a feature bullet, the Privacy bullets above, and "learned"
  added to the vocabulary sentence in the engine section.
- `CHANGELOG.md` under `## [Unreleased]`: **Added** learning words from
  corrections, the style note per category, and the Learning section;
  **Changed** Undo on the "Learned" toast and the source labels in the
  vocabulary list; **Fixed** Reset to Defaults no longer clears custom
  vocabulary (issue 15). No version bump and no dated section.
- `AGENTS.md`: a `voxline/Learning/` line in the directory map.
- `docs/issues.md`: mark 15 fixed.
- `docs/release/MANUAL_TESTS.md`: the Learning section below.

## Testing (Swift Testing)

| File | Covers |
|---|---|
| `InsertAnchorTests` | Text ending at the caret; caret not after the text → nil; non-zero selection → nil; prefix and suffix at 32 units, snapped outward around emoji, flags, and CRLF; field start and end giving empty prefix or suffix. |
| `RegionLocatorTests` | Unchanged; a word edited inside; text typed before the prefix and after the suffix; prefix found twice → ambiguous; prefix edited → ambiguous; empty prefix at 0; empty suffix at the end; oversized region → ambiguous; < 25% → discarded; UTF-16 offsets with surrogate pairs. |
| `WordTokenizerTests` | Joiners ("don't", "Node.js", "e-mail"), punctuation, newlines, emoji, ranges. |
| `TokenDiffTests` | Substitution, 2→1 merge, insertion, deletion, several hunks, the 1,000-token cap. |
| `SimilarityTests` | Levenshtein; a phonetic-key table (Kubernetes / Cooper Nettis, Claude / clod, digits); both sides of each threshold. |
| `CorrectionClassifierTests` | The worked-cases table, with a fake `WordDictionary`; the heavy-rewrite guard; mid-sentence after the prefix; term-shape limits. |
| `CorrectionWindowTests` | With `ManualClock` and a scripted `CorrectionReading`: ends at 30 s; ends on a focus change and on `.absent`; `.failed` keeps it open; `captureWillStart` ends it without waiting; a stale token is dropped; one anchor retry after 300 ms; final read failure with no snapshot → skipped; **final read of an emptied field (`.discarded`) after a `.changed` tick → the last good snapshot is diffed**; a final `.ambiguous` or unreadable read → last good snapshot used; `.unchanged` and `.discarded` ticks never replace a stored snapshot; a later `.changed` tick replaces an earlier one; a final `.unchanged` wins over a stored snapshot (the edit was reverted). Plus `resolve(final:lastGood:)` as a pure table test. |
| `LearningCoordinatorTests` | Both toggles off → no reader calls and no store writes; terminal and untrusted apps skip; candidates deduped against the vocabulary and the rejected list; the toast's action undoes and rejects; the announcement waits for `.idle` and drops after 60 s; final texts and pairs recorded per the rules; refresh starts at 20, not when edited, not twice at once; failure resets the counter; `reset()` removes only learned words. |
| `LearningStoreTests` | Round trip; tolerant decode (missing fields, unknown category key, `version` absent); a corrupt file moved aside; caps (20, 10, 600, 500, 200). |
| `CustomVocabularyStoreTests` | No sidecar → all `user`; `addLearned`; remove and save prune the sidecar; `removeAll` returns sources; `load()` unchanged. |
| `CustomVocabularyListViewModelTests` | Learned label; removing a learned term rejects it, removing a user term doesn't; Clear All. |
| `StyleNotePromptTests` | Input caps and oldest-first dropping; with and without a note and pairs. |
| `LLMServiceTests` | `learnedStyle == nil` → prompt identical to today's (pinned string); note only, examples only, both; escaping; `styleNote` request shape, empty reply → error. |
| `CapturePipelineTests` | `didInsert` only after `.inserted` for dictation and retry, never for commands, presets, copies, or errors; `captureWillStart` from `startRecording`, retry, and preset; `customVocabulary` refreshed and `learnedStyle` set before cleanup. |
| `GeneralSettingsViewModelTests` | `reset_restores_spec_defaults…` now asserts the vocabulary survives. |
| `AppStateTests`, `PillLayoutTests` | `toastAction` is set and cleared together with the message; a later toast clears an earlier action. |
| `LearningSettingsViewModelTests` | Toggles persist; an edit sets `editedByUser` after the debounce; Regenerate confirmation only when edited; status-line text. |

## Manual tests (`docs/release/MANUAL_TESTS.md`, new "Learning" section)

1. **Word, Cocoa.** In TextEdit, dictate "ask Cooper Nettis to review". Change
   it to "Kubernetes" in the field and wait 30 s. "Learned: Kubernetes"
   appears, and Settings shows it labeled Learned. Dictate the sentence
   again: it comes out right.
2. **Fix then send.** In Messages, dictate "ask Cooper Nettis", fix it to
   "Kubernetes", wait 2 s, and press Return. "Learned: Kubernetes" appears.
   Repeat in a Mail compose by fixing, then clicking Send.
3. **Fix then dictate at once.** Same as 1, but start the next dictation
   within 5 s of the fix. The toast appears after that dictation inserts,
   and that dictation already has the word right (through cleanup).
4. **Undo.** Click Undo on the toast. The word leaves the list. Make the same
   fix again: nothing is learned.
5. **Not vocabulary.** Change "Tuesday" to "Thursday", "there" to "their",
   and the case of a word: nothing is learned.
6. **Focus leaves.** Dictate in Notes, click into another app, and edit
   nothing: the log shows `end=focusLeft region=unchanged`.
7. **Electron and web.** Dictate and fix a word in Slack, then in Gmail in
   Safari. Learning either works or logs `valueUnreadable`. No toast is
   wrong, and nothing slows down.
8. **Skipped fields.** Terminal, VS Code, and a password field log a skip and
   never toast.
9. **Style.** After 20 Slack dictations, Settings → Learning → Chat shows a
   sensible note. With `VOXLINE_TRACE_LLM=1`, the next Slack dictation's
   system prompt carries the note and at most two quoted Slack examples, and
   its output follows the note.
10. **Edited note.** Edit the Chat note. After 20 more Slack dictations it is
   unchanged and says "Edited by you". Regenerate asks, then replaces it.
11. **Both off.** Turn both toggles off. A traced dictation's system prompt
    matches a build without this phase, `log stream` shows no `learning`
    lines, and a fix in the field learns nothing.
12. **Issue 15.** Reset to Defaults leaves the vocabulary and Learning alone.
    Clear All asks before removing anything.
13. **Reset Learning.** It asks, then empties the notes and removes only the
    learned words; words added by hand stay.
14. **Latency.** 20 Slack dictations with both toggles off, then 20 with
    both on: the Diagnostics `totalMs` median is within 5%.

## Done when

- Dictate a name the engine misspells into a Cocoa field, fix it, and dictate
  it again: it comes out right, and the "Learned" toast's Undo works.
  (Electron apps learn only where their AX value is readable; manual test 7
  records which do.)
- Fix a dictated name in Messages and press Return within the window: it is
  learned from the last snapshot taken before the send.
- After 20 Slack dictations, the Chat style note exists, reads sensibly, and
  a new Slack dictation visibly follows it. This needs no AX reads: final
  texts fall back to the inserted text.
- Turning both toggles off restores pre-learning behavior exactly: no AX
  calls after insert, and a system prompt identical to today's (unit-tested
  and checked in a trace).
- Reset to Defaults no longer clears the vocabulary (issue 15).
- The `totalMs` median is within 5% with learning on.

## Open questions resolved here

| Question | Resolution | Why |
|---|---|---|
| Window length | 30 s | Ruling 1. |
| Phonetic threshold | `d ≤ 0.34`, or `d ≤ 0.6` with equal keys | It passes every worked case and rejects the dictionary-word swaps. |
| N for refresh | 20 | Ruling 5. |
| `kAXValueChangedNotification` | Not used at all | The 1 Hz value poll already gives the last good snapshot. An early signal would add an observer without changing the result. |
| Fix then send | Diff the last `.changed` snapshot from the poll when the final read can't locate the region | Maintainer ruling: chat and mail sends are a primary case. |
| Anchor context length | 32 UTF-16 units on each side | Long enough to be unique in prose, short enough to survive the user editing nearby. |
| Where style rides | `CapturedContext.learnedStyle` | It reaches the system prompt with no protocol change. |
| Toast while busy | Deferred to idle, dropped after 60 s | The recording pill would hide it. |
| Learning data on Clear History | Untouched | Separate controls, both documented. |

## Out of scope

Observing command and preset edits; learning from text typed without
dictating; a per-app (rather than per-category) style note; editable per-app
prompts; syncing learning data between Macs; WhisperKit vocabulary biasing
(it still ignores hints, and cleanup covers it).
