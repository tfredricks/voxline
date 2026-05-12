# Custom vocabulary — cleanup-only pivot

Supersedes the "Mechanism" section of `2026-05-12-custom-vocabulary-design.md`. That spec called for a dual-pipeline approach: bias the WhisperKit decoder via `promptTokens` **and** correct the transcript at LLM cleanup. After several iterations on the WhisperKit side (prose-prefix prompt wrappers, four threshold disables) the decoder path still produces empty output for short non-prose term lists on synthesized audio, reproduced by `VocabPipelineIntegrationTests`. WhisperKit's own roadmap flags prompt-based biasing as needing model-level work, and the project's reference `testPromptTokens` test only works with full prose prompts on the JFK clip.

This pivot removes the WhisperKit decoder-biasing path entirely. Vocabulary continues to bias the final output through the LLM cleanup prompt — a path that is already wired up and shipping.

## Goal

Make custom vocabulary reliable by routing it through a single, working channel (LLM cleanup), and remove the broken parallel channel (WhisperKit `promptTokens`).

## Non-goals

- Restoring or fixing WhisperKit decoder biasing. If `argmax-oss-swift` later lands the roadmap item for multi-token TextDecoder prompting, we can revisit; until then, treat the API as unreliable for our use case.
- Adding per-mode or per-app vocab scoping.
- Adding pronunciation pairs, categories, or bulk import.

## Pipeline after the pivot

```
audio ─► TranscriptionService.transcribe(samples:)        // no vocab
       ► raw transcript
       ► LLMService.cleanup(transcript:, mode:, context:)  // context.customVocabulary biases here
       ► final
```

Vocabulary reaches the LLM via the existing `ContextCaptureService` → `CapturedContext.customVocabulary` → `ContextBlockFormatter` → `Custom vocabulary:` line path. `LLMService.transcriptionPreamble` already contains the rules (LLMService.swift:44-58) — three worked examples (`LangGraph`, `MSL`, `Argmax`) and a "never invent terms not in the list" guard.

## Changes

### Deletions

| File / symbol | Notes |
|---|---|
| `voxline/Transcription/WhisperPromptBuilder.swift` | Whole file |
| `voxlineTests/WhisperPromptBuilderTests.swift` | Whole file |
| `VocabularyTokenizing` protocol + `WhisperTokenizerVocabularyAdapter` | Lived in WhisperPromptBuilder.swift and TranscriptionService.swift:282-300 respectively |
| `TranscriptionService.tokenCount(for:)` | Only consumer was the settings token-budget footer |
| `vocabulary:` parameter on `Transcribing.transcribe` and `TranscriptionService.transcribe` | Signature becomes `transcribe(samples:)` |
| The decoder-options branch that disables `compressionRatioThreshold`, `logProbThreshold`, `firstTokenLogProbThreshold`, `noSpeechThreshold` | Restore plain `DecodingOptions()` |
| `CapturePipeline.swift:147-148` vocab read + pass-through | Vocab continues to reach LLM cleanup via `ContextCaptureService` |
| `CustomVocabularyListView` token-count footer (`"N terms · X / 200 tokens"` + approximate-flag indicator) | Replaced by plain `"N terms"` |
| `CustomVocabularyListViewModel`: `tokenCount`, `tokenCountIsApproximate`, `budget`, `tokenCounter`, `heuristicCount`, `recomputeTokens` | Initializer collapses to `(store:)` |

### Retained

- `CustomVocabularyStore` (storage format unchanged: `[String]` in UserDefaults)
- `CustomVocabularyListView` add/remove/edit row UI, trim + dedupe semantics, all term-level operations
- `ContextCaptureService.vocabulary` and `CapturedContext.customVocabulary`
- `ContextBlockFormatter` `Custom vocabulary:` line emission
- `LLMService.transcriptionPreamble` vocabulary rules

### UI

`CustomVocabularyListView` footer becomes `"N term"` / `"N terms"`. No budget UI, no approximate-flag indicator.

`SettingsView` and `voxlineApp` construction sites for `CustomVocabularyListViewModel` simplify to pass just the store.

## Tests

### Removed

- `WhisperPromptBuilderTests` (file deleted)
- The current `VocabPipelineIntegrationTests` (assertions on the Whisper-prompt path no longer apply)

### Added

A new live end-to-end integration test, `VocabCleanupIntegrationTests`, in `voxlineTests/Integration/`:

- Tagged `@Tag .integration` so it doesn't run in the fast suite.
- Skip behavior (printed `[integration] skipping…` note, test passes) when **either** the WhisperKit model is not cached **or** the configured LLM provider's API key is absent from the Keychain. Same shape as the existing model-cache skip.
- Provider selection: read `AppSettings.llmProvider`; use the matching Keychain account. The test exercises whichever provider is configured locally; CI without keys skips cleanly.
- Steps:
  1. Synthesize speech for a phrase designed to produce phonetic near-misses for vocab terms, e.g. `"Please use lang graph and arg max in the report"`.
  2. Run real `TranscriptionService.transcribe(samples:)`. Expect non-empty raw transcript.
  3. Construct a `CapturedContext` with `customVocabulary = ["LangGraph", "Argmax"]` and otherwise minimal fields.
  4. Construct a `Mode` with `temperature: 0.0` and a generic style prompt.
  5. Call real `LLMService.cleanup(transcript:, mode:, context:)`.
  6. Assert cleaned output contains case-sensitive `"LangGraph"` **and** `"Argmax"`.

Cost: roughly $0.001 per run, paid by whoever runs the integration suite.

### Unchanged

Existing unit tests for `LLMService`, `ContextBlockFormatter`, `ContextCaptureService`, and `CustomVocabularyStore` cover the cleanup-prompt path and remain valid.

## Data migration

None. `CustomVocabularyStore` schema is unchanged; the stored payload is still `[String]`.

## Risk & rollback

- The cleanup-layer path is already running in production. Removing the Whisper-prompt path is strictly a deletion of broken parallel behavior.
- If a regression appears at the cleanup layer (separate from this change), revert with `git revert <commit>` — no data state to roll back.

## Out-of-scope follow-ups

- Soft cap warning if a user accumulates an unusually large vocab list (e.g. >200 terms) that meaningfully inflates the cleanup prompt.
- Per-mode vocab scoping.
- Revisiting WhisperKit decoder biasing if `argmax-oss-swift` ships the roadmap multi-token TextDecoder prompting feature.
