# Custom vocabulary — design

Feature 8 of the roadmap (`docs/features.md`):

> **Custom vocabulary** — Lets users add names, company terms, acronyms, technical terms, product names, and personal shorthand so transcription gets them right.

A stub already exists in code (`CustomVocabularyStore`, a single-line settings TextEditor, an empty `Custom vocabulary:` line in the LLM context block). This spec replaces the stub with a real feature.

## Scope

v1 fixes three transcription failure classes:

1. **Wrong word entirely** — Whisper mishears the term (e.g. "are max" instead of "Argmax"). LLM cleanup cannot recover what Whisper never produced, so this requires biasing the decoder itself.
2. **Right word, wrong spelling/casing** — Whisper produces a phonetically close form ("vs code", "langgraph", "voxline"). LLM cleanup can normalize this if explicitly instructed.
3. **Acronym handling** — Initialisms split, joined, or expanded incorrectly ("M S L" vs "MSL"). Same mechanism as case (2).

Out of scope for v1: per-mode / per-app vocab lists, pronunciation-pair entries, categories, bulk import, automatic seeding.

## Mechanism

A single global flat list of canonical terms feeds two pipeline stages:

```
audio ─► WhisperKit.transcribe(promptTokens = tokenize("Argmax, LangGraph, MSL, voxline."))
       ► transcript
       ► LLMService.cleanup (preamble: normalize transcript words to canonical list)
       ► final
```

Shared list semantics keep the data model simple: one term means "this is the canonical form; recognize it during transcription, spell it this way during cleanup."

## Architecture

Two new units, two revised, one UI section replaced.

```
push-to-talk
  └─ AudioCapture
      └─ TranscriptionService                            (revised)
          ├─ reads vocabulary: [String]
          ├─ WhisperPromptBuilder → promptTokens          (new)
          └─ WhisperKit.transcribe(DecodingOptions(promptTokens:))
              └─ transcript
                  └─ LLMService.cleanup                  (preamble revised)
                      ├─ context.customVocabulary         (unchanged plumbing)
                      └─ system preamble: active normalization rule
                          └─ cleaned text → paste

Settings / Custom vocabulary
  └─ CustomVocabularyListView                            (new, replaces TextEditor)
      ├─ rows: terms + delete
      ├─ "Add term" field with budget-aware enable
      └─ footer: "N terms · X / 200 tokens"
```

Boundaries:

- `CustomVocabularyStore` (existing) owns persistence. Doesn't know about WhisperKit.
- `WhisperPromptBuilder` (new) is a pure function of `(terms, tokenizer)`. Doesn't know about UserDefaults.
- `TranscriptionService` (revised) doesn't know how prompts are built — it accepts `vocabulary: [String]` and delegates.
- `LLMService` (revised) reads `context.customVocabulary` as today; only its system preamble changes.
- `CustomVocabularyListView` (new) talks to the store and a token-count source; doesn't reach into WhisperKit directly.

Each unit is testable in isolation: store against in-memory `UserDefaults`; builder against an injected fake tokenizer; preamble via snapshot; view-model with fake count source.

## Components

### `CustomVocabularyStore` — no changes

The existing implementation in `voxline/Storage/CustomVocabularyStore.swift` is fit for purpose. `load()`, `save(_:)`, `parse(_:)`, and `normalize(_:)` stay. The stub comment referring to "feature #9 per-mode dictionaries" is now stale and should be removed; this feature settles the file's responsibility.

### `WhisperPromptBuilder` — new

Location: `voxline/Transcription/WhisperPromptBuilder.swift`.

```swift
struct WhisperPromptBuilder {
    /// WhisperKit caps promptTokens at maxTokenContext/2 − 1 = 223 for the
    /// standard 448-context models. We cap at 200 so the UI counter agrees
    /// with what's actually used and we leave headroom for future model
    /// variants with slightly different limits.
    static let promptTokenBudget = 200

    /// Compact, naturally-occurring joiner: comma-space, trailing period.
    /// Empty list → empty string.
    static func promptString(from terms: [String]) -> String

    /// Tokenize via the active WhisperKit tokenizer, filter special-token
    /// IDs, and truncate from the tail so terms are kept in user-order.
    /// Empty list → empty array. Caller must omit promptTokens entirely
    /// when the result is empty (WhisperKit treats [] differently from nil).
    static func promptTokens(
        from terms: [String],
        tokenizer: WhisperTokenizer,
        budget: Int = promptTokenBudget
    ) -> [Int]

    /// Live count for the Settings UI. Uses the same tokenization path so
    /// the number matches what transcribe will actually use.
    static func tokenCount(of terms: [String], tokenizer: WhisperTokenizer) -> Int
}
```

The exact `WhisperTokenizer` protocol surface used here is whatever `WhisperKit.tokenizer` exposes — a single `encode(_:)` method is enough; the builder defines a minimal protocol over that so tests can supply a fake.

### `TranscriptionService` — revised

Add `vocabulary: [String]` to `transcribe(samples:)`:

```swift
func transcribe(samples: [Float], vocabulary: [String] = []) async throws -> String
```

Inside, after `loadIfNeeded()` returns a `WhisperKit` (and therefore its tokenizer), build the prompt:

```swift
let kit = try await loadIfNeeded()
let tokens = WhisperPromptBuilder.promptTokens(from: vocabulary, tokenizer: kit.tokenizer)
let options: DecodingOptions = tokens.isEmpty
    ? DecodingOptions()
    : DecodingOptions(promptTokens: tokens)
let results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
```

Also add a public helper for the Settings counter:

```swift
/// Async because counting requires the tokenizer, which lives behind the
/// model load. Settings calls this on appear; the model load it triggers
/// is the same one the first dictation would have triggered.
func tokenCount(for terms: [String]) async throws -> Int
```

The Whisper model variant influences tokenization density (a name that's two tokens under `tiny` may be one or three under `large-v3`). The view-model invalidates its cached count when `whisperModel` changes; the existing `loadTask` machinery already serializes the swap.

### `CapturePipeline` — revised one line

`finalizeRecording` reads the vocab from the store (already injected via `ContextCaptureService`'s `vocabulary` member, but we want it directly here rather than going through context):

```swift
let vocab = vocabularyStore.load()
transcript = try await transcriber.transcribe(samples: samples, vocabulary: vocab)
```

`CapturedContext.customVocabulary` is still populated by `ContextCaptureService` from the same store — no change to that path. Reading the list twice in a single dictation is fine (two cheap defaults reads).

The pipeline's initializer grows a `vocabularyStore: CustomVocabularyStore` dependency, defaulting to `CustomVocabularyStore()` for production wiring.

### `LLMService.transcriptionPreamble` — revised paragraph

Today:

> "If a Context section follows the transcript, treat it as background signal: ground proper nouns and spellings against it, match the register and punctuation density of any surrounding text shown, and **preserve any listed vocabulary verbatim.** Never quote, echo, or summarize Context fields — the transcript is the only source of text to return."

Revise the bolded clause to an active normalization rule:

> "If a `Custom vocabulary` line appears in the Context block, treat each comma-separated entry as a **canonical spelling**. When a transcript word is phonetically close to one of those entries but differs in spelling, case, word-segmentation, or letter-spacing, replace the transcript form with the canonical form. Never invent terms that are not in the list. If a vocabulary term appears consecutively two or more times with no other content between, collapse it to a single occurrence."

The trailing "collapse consecutive duplicates" rule mitigates the known Whisper prompt-bias failure mode where a biased term occasionally repeats in the output.

Beyond the normalization paragraph itself, the spec does not constrain the rest of the preamble — keep the existing rules about fillers, disfluencies, self-corrections, and verbatim proper-noun preservation as they are.

### `CustomVocabularyListView` — new

Location: `voxline/Settings/Components/CustomVocabularyListView.swift`.

A SwiftUI section view bound to a small view-model that wraps `CustomVocabularyStore` and a token-count source.

```
Custom vocabulary
──────────────────────────────────────────────
  Argmax                                  [—]
  LangGraph                               [—]
  MSL                                     [—]
  voxline                                 [—]
  [ + Add term ]   text field             [ Add ]

  5 terms · 9 / 200 tokens
```

Behavior:

- Empty state shows "Add names, products, and acronyms that get mis-transcribed."
- Rows render `viewModel.terms` in stored order. Each row has a delete button.
- "Add term" textfield is cleared on successful add. Trims whitespace, ignores exact duplicates silently. The Add button is disabled when the typed term would push the live count over budget.
- Footer shows `<term count> terms · <token count> / 200 tokens`.
- Token count is async; while a recompute is in flight, the prior count is shown (the recompute is fast enough that this is rarely visible).
- If the tokenizer is unavailable (Whisper model not yet loaded and `prewarm` failed), fall back to a 1.3-tokens-per-word heuristic and show "Token count is approximate" below the footer. Editing is never blocked on the tokenizer.

Wire-up: `SettingsView` replaces the existing `Section("Custom vocabulary")` block with `CustomVocabularyListView(...)`. The `GeneralSettingsViewModel.customVocabularyText` property and its setter (which currently re-parses and re-saves on every keystroke) are deleted along with the TextEditor.

## Data flow

**During a dictation.**

1. Hotkey down → `CapturePipeline.startRecording`. Audio capture begins. Context capture starts in parallel; the context probe reads the vocab list into `CapturedContext.customVocabulary`.
2. Hotkey up → `CapturePipeline.finalizeRecording`. Pipeline reads the vocab list a second time (independent of the context capture task) and passes it to `transcriber.transcribe(samples:vocabulary:)`.
3. `TranscriptionService` ensures the model is loaded, builds `promptTokens`, calls `WhisperKit.transcribe` with `DecodingOptions(promptTokens:)`.
4. Transcript flows to `LLMService.cleanup`. The Context block (built by `ContextBlockFormatter`) already includes `- Custom vocabulary: ...`. The revised preamble instructs the model to normalize against it.
5. Cleaned text → paste.

**While editing the list in Settings.**

1. View loads. View-model reads `store.load()`. Triggers an async token-count refresh.
2. User types into the Add field. The view-model probes "would adding this exceed budget?" — if yes, Add button stays disabled. Concretely: tokenize the typed string in isolation against the same tokenizer, compare `cached_total + typed_count + joinerCost` to the budget. `joinerCost` is a small fixed value (the tokens for ", ") computed once. An exact recompute over the whole list fires on Add.
3. User taps Add. View-model appends, calls `store.save(_:)`, kicks off a fresh recompute.
4. User taps delete on a row. View-model removes, calls `store.save(_:)`, recomputes.
5. User switches Whisper model in another section. The view-model observes `whisperModel`; on change, invalidate cached count and recompute against the new tokenizer.

## Error handling & edge cases

**Tokenizer not available yet.** First open of Settings before any dictation. Show "Counting tokens…" inline; trigger `prewarm()` if not already running; render the rows immediately so editing isn't blocked. If load fails, fall back to the heuristic estimate and show the "approximate" note. Editing always works.

**Over-budget at transcribe time.** UI hard-caps Add, so this shouldn't happen. But a model swap can change tokenization density: a list that fit under `tiny` might not fit under `large-v3`. `WhisperPromptBuilder.promptTokens` truncates from the tail and a debug log records `vocab_truncated: kept=N dropped=M`. The full list still flows to LLM cleanup. No user-facing error.

**Empty vocab.** Builder returns `[]`. `TranscriptionService` omits `promptTokens` from `DecodingOptions` (does not pass an empty array). `ContextBlockFormatter` already suppresses the `- Custom vocabulary:` line when empty. End-to-end behavior matches current code.

**Term tokenizes to special tokens only.** WhisperKit filters tokens at or above `specialTokenBegin`. Such a term silently contributes zero tokens to the Whisper prompt; it still appears in the LLM context. Acceptable.

**Whisper model swap mid-edit.** View-model invalidates cached count and recomputes against the new tokenizer once the swap completes. The serialization is handled by the existing `loadTask` machinery in `TranscriptionService`.

**Duplicate / case-variant entries.** Exact duplicates are silently ignored on Add. Case variants (`voxline` vs `Voxline`) are allowed — the existing `CustomVocabularyStore.normalize` is intentionally case-sensitive because both forms can be legitimate.

**Very long single term.** A 50-word "term" would eat the budget. The Add-button enable check covers this (the typed text alone exceeds the remaining budget → disabled).

**Persistence corruption.** `defaults.stringArray(forKey:)` returns nil on any unexpected type; `load()` returns `[]`. User re-enters terms. No recovery path; data is reproducible.

**LLM ignores normalization instruction.** Non-deterministic model behavior is the failure mode. The existing "preserve proper nouns verbatim" rule is the safety net — the worst case is degraded canonicalization, not corruption. Prompt iteration is the fix, not a code fallback.

**Whisper prompt hallucination (repeated terms).** Mitigated by (a) keeping the joined prompt string short and well-formed and (b) the LLM preamble's "collapse consecutive duplicates" rule.

**Secure field.** Vocab is already exempted from secure-field suppression in `ContextBlockFormatter` — it's not value-bearing text. Whisper bias also still fires; vocab terms are not sensitive in the same sense as before/after-cursor text.

## Testing

### New tests

`WhisperPromptBuilderTests` (fake tokenizer, no WhisperKit dependency):

- `promptString_joins_terms_with_comma_space_and_trailing_period`
- `promptString_returns_empty_when_no_terms`
- `promptTokens_returns_empty_when_no_terms`
- `promptTokens_truncates_from_tail_when_over_budget` — 50 terms tokenizing to 300 total tokens; assert returned IDs come from the first N terms only
- `promptTokens_filters_special_token_ids` — fake tokenizer emits a special-ID; assert it's dropped
- `tokenCount_matches_promptTokens_length_when_under_budget`

`CustomVocabularyListViewModelTests`:

- `addTerm_trims_and_persists`
- `addTerm_ignores_exact_duplicate`
- `addTerm_disabled_when_budget_full`
- `removeTerm_persists`
- `modelSwitch_invalidates_cached_count`
- `tokenizerUnavailable_fallsBackToHeuristic`
- `loadFromStore_populates_terms_in_order`

### Modified tests

`TranscriptionServiceTests`:

- New: `transcribe_with_empty_vocab_omits_promptTokens` — verify `DecodingOptions.promptTokens == nil`, not `[]`
- New: `transcribe_with_vocab_passes_promptTokens` — verify token IDs match what the builder would produce against the same fake tokenizer
- Existing tests get a `vocabulary: []` argument; no behavior change.

`LLMServiceTests` (or new `TranscriptionPreambleTests`):

- Snapshot test of the revised preamble paragraph so future edits are deliberate.

`CapturePipelineTests`:

- Existing tests wire the new vocab-loading line with a fake store returning `[]`; no behavior change.
- New: `finalize_passes_loaded_vocab_to_transcriber` — fake store returns `["Argmax"]`; fake transcriber records its `vocabulary` argument.

`ContextBlockFormatterTests` / `ContextCaptureServiceTests` / `CustomVocabularyStoreTests`: unchanged.

### Manual smoke checklist

1. Empty list → existing dictation behavior unchanged.
2. Add "Argmax" + "LangGraph" → dictate "the are max team shipped lang graph" → final text says "the Argmax team shipped LangGraph".
3. Add a clearly novel term ("Zorblax") → dictate it → it appears spelled correctly.
4. Add ~250 terms via repeated Add → Add disables around the budget; counter pegs at `200 / 200 tokens`.
5. Switch Whisper model from `tiny` to `large-v3` with vocab populated → token counter recomputes; no crash; next dictation still works.
6. Delete all terms → transcription continues to work; LLM context omits the vocab line.
7. Settings → Reset to Defaults → vocab list clears (existing reset path calls `vocabulary.save([])`).

### Out of scope for tests

- Real WhisperKit-level effectiveness of biasing (stochastic; not a unit-test concern).
- LLM canonicalization accuracy (prompt quality is iterated, not asserted).
- Performance — parse + tokenize is O(N) on a handful of terms; cheaper than any other pipeline stage.

## Files touched

New:

- `voxline/Transcription/WhisperPromptBuilder.swift`
- `voxline/Settings/Components/CustomVocabularyListView.swift`
- `voxlineTests/WhisperPromptBuilderTests.swift`
- `voxlineTests/CustomVocabularyListViewModelTests.swift`

Modified:

- `voxline/Transcription/TranscriptionService.swift` — add `vocabulary:` to `transcribe`; add `tokenCount(for:)` helper.
- `voxline/Pipeline/CapturePipeline.swift` — read vocab; pass to `transcribe`.
- `voxline/LLM/LLMService.swift` — revised preamble paragraph.
- `voxline/Settings/SettingsView.swift` — replace `Section("Custom vocabulary")` block with `CustomVocabularyListView`.
- `voxline/Settings/GeneralSettingsViewModel.swift` — drop the `customVocabularyText` property and its observer that re-parses on every keystroke; keep the `vocabulary: CustomVocabularyStore` member because `resetToDefaults()` still uses it.
- `voxline/Storage/CustomVocabularyStore.swift` — remove stale "stub for feature #9" comment.
- `voxlineTests/TranscriptionServiceTests.swift`, `voxlineTests/CapturePipelineTests.swift`, `voxlineTests/GeneralSettingsViewModelTests.swift` — see Testing section.

## Open questions

None known. The Whisper prompt-bias mechanism is confirmed available in WhisperKit 1.0.0 (`DecodingOptions.promptTokens`, capped at `maxTokenContext/2 − 1`). The LLM preamble change is a wording-only iteration. The UI shape is conventional SwiftUI.
