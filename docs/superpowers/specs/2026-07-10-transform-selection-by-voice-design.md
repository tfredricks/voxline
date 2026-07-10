# Transform Selection by Voice — Design

**Date:** 2026-07-10
**Status:** Approved design, ready for implementation planning

## Summary

Extend Voxline beyond dictation: let the user **highlight arbitrary text in any app,
press the dictation hotkey, speak a command** (e.g. "make this cleaner," "turn this
into bullet points," "make it more formal"), and have Voxline rewrite the highlighted
text in place. This generalizes today's fixed `Shorter / Longer / Clearer` refine
buttons — which only operate on *just-dictated* text — into free-form spoken commands
over *any* selected text.

Most of the required plumbing already exists (reading the selection, replacing text in
place, the review pill, refine chaining). The genuinely new work is (1) a branch on
"is there a selection when the hotkey fires" and (2) a second, instruction-following
LLM prompt path.

## Goals

- Highlight text anywhere → speak a command → text is rewritten in place.
- Reuse the existing review pill so `Shorter / Longer / Clearer` chain on the result.
- Keep the change minimal by reusing existing AX read/write and LLM machinery.

## Non-Goals

- Translation, summarization, question-answering, or adding new facts/content
  (see Command Scope). These are explicitly out of scope for the transform prompt.
- Overwrite-by-dictation (select text, dictate fresh text to replace it). The user
  confirmed they never do this, so auto-detect can unconditionally treat
  "selection + speech" as a transform command. No escape hatch in v1.
- Changing today's plain dictation behavior when nothing is selected.

## Interaction Model

**Auto-detect selection.** No new hotkey or gesture.

```
Press dictation hotkey
  ├─ selection is non-empty?  → TRANSFORM MODE
  │     capture audio → Whisper transcribes the COMMAND
  │     → LLM(command = spoken words, payload = selection)
  │     → replace the live selection with the result
  │     → open review pill (Shorter / Longer / Clearer / ×); ⌘Z to undo
  └─ selection empty?         → DICTATE (today's behavior, unchanged)
```

The only branch point is "is there a non-empty selection at the moment the hotkey
fires." Everything downstream reuses existing machinery.

## Command Scope: Rewrite + Restructure

The transform path supports:

- **Rewrite:** tone, length, clarity, grammar — "make it cleaner / more formal /
  shorter / fix grammar."
- **Restructure of the same content:** bullet points, numbered lists, reordering,
  splitting sentences.

It explicitly does **not**:

- Add new facts or content.
- Translate.
- Summarize or answer questions.

When a spoken command falls outside this scope (or sounds like content rather than an
instruction), the model returns the selection **unchanged** and Voxline shows a brief
"Couldn't apply that" toast rather than silently mangling the text.

## Architecture

Grounded in the current codebase (`voxline/`):

### 1. Detect selection & branch — `CapturePipeline`

`CapturePipeline.finalizeRecording()` (`voxline/Pipeline/CapturePipeline.swift:149`)
currently: transcribe → resolve mode → `llm.cleanup(...)` → insert → review session.

Change: after transcription, check for a non-empty selection (via the context probe /
`FocusedTextSystem`). If present, take the **transform branch** instead of the dictate
branch. The selection must be read (or re-read) at command time to get the full payload,
not just the 500-char context sample.

### 2. Read the selection — reuse AX, larger cap

`DefaultAXContextProbe.probe` (`voxline/Context/AXContextProbe.swift:40`) already reads
`kAXSelectedTextAttribute` off the system-wide focused element, but caps it at
**500 chars** (`selectedTextMax`) because it is only background context today.

**Decision (approved):** as the *primary payload*, 500 chars (~80 words) is too small.
The transform path reads the selection with a **separate, larger cap** (leave the
context-probe cap untouched). Correspondingly, the LLM `maxOutputTokens` of **1024**
(`voxline/LLM/LLMProvider.swift:35`) may need raising for large selections; the
transform request should use a higher output-token budget than the dictation path.

### 3. New instruction-following prompt path — `LLMService`

Today's system prompt (`transcriptionPreamble`, `voxline/LLM/LLMService.swift:15`) is a
*transcription post-processor* that is explicitly forbidden from obeying the audio. That
is the wrong prompt for a feature whose entire point is to obey the spoken command.

Add a **second system prompt** for transform, selected by mode. Its guardrails encode
the Command Scope:

- Apply the user's instruction to the provided text.
- **Rewrite and restructure only.** Preserve meaning and all facts.
- **Add no new information. Do not translate.**
- Return only the transformed text — nothing else.
- If the instruction cannot be applied as a rewrite/restructure of the text, return the
  text unchanged.

The user prompt carries the spoken command as the instruction and the selection as the
payload (distinct from today's `Raw transcript:` framing in
`ContextBlockFormatter`, `voxline/Context/ContextBlockFormatter.swift:30`).

`RefinementDirective` (`voxline/LLM/RefinementDirective.swift`) is unchanged — it still
backs the pill buttons.

### 4. Write back over the live selection — `ClipboardInjector`

Because the user's selection is **already live**, write-back is simpler than the
existing `ClipboardInjector.replace()` (`voxline/Output/ClipboardInjector.swift:575`),
which re-selects text *ending at the caret*. Here we can paste directly over the live
selection:

- Paste the result over the current selection (`injectViaClipboardPaste`).
- Keep the **keystroke-selection fallback** (`replaceViaKeystrokeSelection`,
  `ClipboardInjector.swift:625`) for AX-hostile editors (Electron/CodeMirror, e.g.
  Obsidian).
- On any doubt, leave the result on the clipboard and show the existing
  "Copied — ⌘V to replace" toast.

### 5. Review & refine chaining — `ReviewSession`

Open a `ReviewSession` (`voxline/Pipeline/ReviewSession.swift`) after the transform, so
the `Shorter / Longer / Clearer` buttons appear as they do after dictation.

**Decision (approved):** the review session's refine source is the **transformed text**,
not the original spoken command. So `Shorter` operates on the result, rather than
re-running the user's command. This differs from today's `refine()`
(`CapturePipeline.swift:240`), which re-runs `llm.cleanup(transcript: session.transcript,
...)` from the original transcript. The transform session stores the current text as its
refine source.

Record the transform via `historyStore` so `updateMostRecent`
(`DictationHistoryStore`) chaining behaves exactly as today.

## Edge Cases

- **Secure fields:** blocked everywhere, unchanged (`focusedFieldIsSecure` /
  `kAXSecureTextFieldSubrole`).
- **Out-of-scope command** (translate, summarize, or content-like speech): model returns
  the selection unchanged; Voxline shows a brief "Couldn't apply that" toast.
- **Empty / failed command transcription:** no-op, selection untouched.
- **Selection changed or focus lost during the LLM call:** reuse the guard added in
  `refine()` (commit e3daa8f) — re-check session/focus after the await; on mismatch, bail
  to the clipboard fallback rather than overwriting the wrong target.
- **LLM failure:** result (or original selection) left on clipboard with the recovery
  toast, consistent with the dictation path's failure recovery.

## Open Questions

- Exact value for the larger transform selection cap and the raised `maxOutputTokens`
  (tune during implementation; verify current model limits via the `claude-api`
  reference before hardcoding).
- Overwrite-by-dictation escape hatch is deferred (user does not need it); revisit only
  if the workflow resurfaces.

## Reused vs. New

**Reused as-is:** selection read (`AXContextProbe`), in-place replace + keystroke
fallback + clipboard fallback (`ClipboardInjector`), review pill + refine buttons
(`RecordingPillView`, `PillReviewActions`), history + `updateMostRecent`, secure-field
blocking, post-await focus/session guard.

**New:** selection-detection branch in `finalizeRecording()`, larger-cap selection read
for the payload, a second instruction-following system prompt + user-prompt framing in
`LLMService`, transform-mode review session whose refine source is the transformed text,
"Couldn't apply that" toast.
