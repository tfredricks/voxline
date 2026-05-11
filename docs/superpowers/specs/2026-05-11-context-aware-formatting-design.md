# Context-Aware Formatting (#11) — Design

Status: design approved, ready to plan
Roadmap item: [docs/features.md #11](../../features.md)

## Goal

Improve LLM cleanup quality by passing structured signals about where the user is dictating into the prompt. Today the LLM sees only the raw transcript and a per-app mode prompt. After this change it also sees the focused app, window title, the focused field's surrounding text, the current selection, a small list of visible labels from the window, and a global custom-vocabulary list.

The mode-routing system (`Modes/`, `AXFocusedFieldInspector`, `FrontmostApp`) already exists. This feature extends what we capture and how we feed it to the LLM. It does not change how modes are selected.

## Scope

In scope:

- New `Context/` module that captures structured context at push-to-talk press time.
- Extended AX probing: window title, focused-field value range (text before/after cursor), selected text, capped AX-tree walk for visible labels.
- A global custom-vocabulary list (stub for feature #9), no UI beyond a single text field in Settings.
- Append a structured `Context:` block to the LLM user message. Mode prompts stay as the system message and are not modified.
- Secure-field handling: capture app + window only; suppress all value-bearing lines.
- 150ms total time budget with per-step deadlines and graceful partial results.
- Diagnostic logging of what was captured.

Out of scope:

- Per-mode or per-app vocabulary (deferred to #9).
- Recent-clipboard signal (excluded — feedback-loop and leakage risk).
- Template variables inside mode prompts.
- New mode UI; existing mode editor unchanged.
- Output-destination classifier or other derived/inferred fields. The LLM works directly from raw signals.

## Architecture

```
voxline/Context/
  ContextCaptureService.swift      // protocol + DefaultContextCaptureService
  CapturedContext.swift            // struct
  ContextBlockFormatter.swift      // CapturedContext -> String
  AXContextProbe.swift             // window title, value range, selected text
  AXVisibleLabelsWalker.swift      // capped BFS over focused window
  CaptureDeadline.swift            // small time-budget helper
  CustomVocabularyStore.swift      // global [String] via UserDefaults
```

Reused without modification:

- `Output/AXFocusedFieldInspector.swift` — role/subrole (already used by `ModeRouter`).
- `Output/FrontmostApp.swift` — bundle ID + localized name.
- `Diagnostics/*` — debug log sink.

The capture entry point sits on `CapturePipeline`. At push-to-talk press (the same instant we start recording), the pipeline calls `ContextCaptureService.capture()` on a background queue. The returned `CapturedContext` is held with the in-flight transcription job and handed to `LLMService` alongside the transcript. The capture runs in parallel with the audio capture phase, so its cost is hidden behind the user holding the hotkey.

`LLMService` composes the call:

- System message: the resolved `Mode.prompt`, unchanged from today.
- User message: built by `ContextBlockFormatter.format(transcript:context:)`.

Both `AnthropicClient` and `OpenAIClient` already accept distinct system/user messages; no client-layer change required beyond the message body.

## Data flow

1. User presses push-to-talk hotkey.
2. `CapturePipeline` starts audio recording **and** dispatches `ContextCaptureService.capture()` on a utility queue. They run concurrently.
3. User releases hotkey. Audio is transcribed. `CapturedContext` is awaited (it has almost always finished by now; 150ms hard cap regardless).
4. `ModeRouter` resolves the mode from `bundleID` + `FocusedField` (existing behavior).
5. `LLMService.cleanup(transcript:mode:context:)` formats the user message and calls the provider.
6. Cleaned text is pasted; the resolved context is written to the diagnostic log at debug level.

If AX trust is not granted, step 2 still runs but only fills `appName`/`bundleID`. The rest of the pipeline is unchanged.

## Data model

```swift
struct CapturedContext: Equatable {
    var appName: String?            // "Slack"
    var bundleID: String?           // "com.tinyspeck.slackmacgap"
    var windowTitle: String?        // "#sales-pipeline — Acme workspace"
    var fieldRole: String?
    var fieldSubrole: String?
    var isSecureField: Bool
    var textBeforeCursor: String?   // ≤ 200 chars
    var textAfterCursor: String?    // ≤ 100 chars
    var selectedText: String?       // ≤ 500 chars
    var visibleLabels: [String]     // ≤ 20 items, each ≤ 60 chars, deduped
    var customVocabulary: [String]
    var captureDurationMs: Int
    var captureNotes: [String]      // diagnostic only; never in prompt

    static let empty = CapturedContext(...)
}
```

All caps are enforced at the `AXContextProbe` / `AXVisibleLabelsWalker` layer — the formatter does not re-trim.

## Capture flow and time budget

Total budget: **150ms hard cap**. Capture order is cheapest-first so the most valuable signals are most likely to land before the cap:

1. Frontmost app (`NSWorkspace`) — bundle ID, localized name. ~1ms, no AX.
2. AX focused element + role/subrole. ~5–20ms.
3. **Secure-field gate:** if `kAXSecureTextFieldSubrole` or matching role hint, set `isSecureField=true`. Skip steps 4 and 6. Continue to 5.
4. AX selected text + `kAXSelectedTextRangeAttribute`; resolve before/after slices via `kAXStringForRangeParameterizedAttribute`. ~10–80ms.
5. Window title via the focused element's parent window. ~5–20ms.
6. AX-tree BFS from the focused window for visible labels. Depth cap 6, count cap 20, per-call deadline check. ~20–100ms.

Each step is wrapped in a `CaptureDeadline.withRemaining(...)` helper. On any miss, append a note to `captureNotes` and continue with the next step. No exceptions cross the `ContextCaptureService` boundary.

## Prompt format

System message: the resolved mode's `prompt`, unchanged.

User message, built by `ContextBlockFormatter`:

```
Raw transcript:
"<transcript>"

Context:
- App: Slack (com.tinyspeck.slackmacgap)
- Window: #sales-pipeline — Acme workspace
- Field: AXTextArea
- Selected text: "the paragraph you highlighted"
- Text before cursor: "Hey Kamil, following up on"
- Text after cursor: ""
- Visible labels: ["Kamil Szczerba", "Q4 Renewal", "Acme"]
- Custom vocabulary: Cursor, LangGraph, canonical_title

Return only the final text to insert. Do not add quotes, prefixes, or commentary.
```

Formatter rules:

- Omit any line whose value is nil or empty — never emit `Context:\n- App: nil`.
- If **every** context field is empty, omit the entire `Context:` header — fall back to today's user-message shape (`Raw transcript: ...` + trailing instruction).
- If `isSecureField=true`: include `App`, `Window`, and `Field: secure`. No value-bearing lines.
- The trailing instruction line is fixed and lives in the formatter, not in mode prompts. This is shared infrastructure that addresses the existing "LLM added a preamble" failure mode independent of context capture.

## Custom vocabulary (stubbed for #9)

- Storage: `CustomVocabularyStore` reads/writes a single `[String]` under a stable `UserDefaults` key.
- UI: a single multiline text field in the existing Settings sheet, comma-or-newline separated. No per-app, no per-mode, no tagging.
- Use: `CustomVocabularyStore.load()` is called once per capture; the list is passed through `CapturedContext.customVocabulary`. The formatter joins with `", "`.
- When #9 lands, this storage is replaced; the field on `CapturedContext` stays the same shape so the formatter doesn't change.

## Error handling and failure modes

| Failure | Behavior |
|---|---|
| AX not trusted | `appName` + `bundleID` only; no Context lines requiring AX. Cleanup still runs. |
| AX call times out | Skip that field, append note, continue with remaining budget. |
| Total capture > 150ms | Return partial `CapturedContext`; never block recording start. |
| Capture throws | Caught at `ContextCaptureService` boundary; pipeline gets `CapturedContext.empty`. |
| LLM call fails | Existing fallback unchanged (raw transcript paste). |
| Mode not resolved | Existing wildcard-mode behavior unchanged. |
| Secure focused field | `isSecureField=true`, value-bearing lines suppressed (see formatter rules). |

The captured context is written to the existing diagnostic log at debug level for every cleanup, including `captureNotes` and `captureDurationMs`. This is what you read when a cleanup looks wrong.

## Testing

Unit:

- `ContextBlockFormatter` — golden-string tests for full context, partial context, all-empty (no Context block), secure-field.
- `AXContextProbe` and `AXVisibleLabelsWalker` against a fake `AXUIElement` protocol facade (same pattern as the existing `FocusedFieldInspecting` test double).
- `CaptureDeadline` — partial results return on cap-bust.
- `CustomVocabularyStore` — round-trip with `UserDefaults` test suite.

Integration:

- `CapturePipeline` test that injects a `FakeContextCaptureService` and asserts the formatted user message reaches `LLMService` with the expected body.
- `LLMService` test that the system message remains the unmodified mode prompt while the user message contains the Context block.

Manual smoke matrix (`docs/insertion-smoke-matrix.md`):

- Add a "Context captured" column for the existing target apps (Mail, Slack, Cursor, Safari, Notes, Terminal).
- Per app: AX trusted yes/no, expected Context lines present, secure-field row (login page) suppresses values.

## Open questions

None. All design decisions made during brainstorming on 2026-05-11.

## Out-of-scope follow-ups

- Feature #9 (custom vocabulary): replaces the stub store with a per-mode model.
- Feature #14 (app-specific integrations): could ship app-tuned mode prompts that lean on the Context block (e.g., a Gmail mode that uses `Window` title to detect "Re:").
- Recent-clipboard signal: revisit only with a strong staleness/sourcing strategy. Today: excluded.
