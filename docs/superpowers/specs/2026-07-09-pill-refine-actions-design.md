# Post-dictation pill refine actions — design

After a successful paste the recording pill vanishes instantly. When the cleanup
was *close but not right* — too wordy, too terse, slightly garbled — the only
recourse today is deleting the text and re-speaking the whole thing. This
feature makes the pill linger briefly with three one-click refinements:

**Terser · Longer · Clearer**

Clicking one re-runs LLM cleanup over the **original transcript** (not the
cleaned output — the transcript retains everything the user actually said) with
a refinement directive, then replaces the just-pasted text in place. Actions
chain: Terser then Clearer is fine; each click replaces the current insertion.

## Scope

v1:

1. Pill lingers ~7s after a successful paste with three action buttons and a ×
   dismiss. Hovering pauses the countdown.
2. Each action re-runs cleanup with a directive and replaces the pasted text
   in place via a verified AX selection swap.
3. Fallback when in-place replace can't be done safely: copy the new version to
   the clipboard and toast "Copied — ⌘V to replace".
4. The dictation's history entry is **updated** to the accepted version — no
   history spam from chained redos.

Out of scope for v1: spoken refinement directives ("make it one sentence"),
raw-transcript swap, retry/re-roll, multiple candidate versions, custom
user-defined refinements, refining dictations older than the current session.

## Mechanism

```
finalizeRecording succeeds (paste done)
  └─ state.reviewSession = ReviewSession(transcript, mode, context,
                                         insertedText, expiresAt)
      └─ pill stays visible, becomes clickable (never activates voxline)
          ├─ [timer expires / × / new chord press] → session scrubbed, pill hides
          └─ [Terser|Longer|Clearer clicked]
              └─ CapturePipeline.refine(directive)
                  ├─ status = .thinking (pill shows existing spinner)
                  ├─ llm.cleanup(transcript, mode, context, refinement: directive)
                  └─ injector.replace(session.insertedText, with: new)
                      ├─ verified AX selection swap → replaced in place
                      │    └─ session.insertedText = new, timer resets,
                      │       history entry updated, buttons return
                      └─ can't verify → clipboard + toast, session stays alive
```

The load-bearing constraint: the pill's panel is `.nonactivatingPanel`, so a
button click must **never** activate voxline or deactivate the frontmost app —
focus stays in the field that was pasted into, otherwise both AX replace and
the ⌘V fallback would target the wrong app.

## Architecture

```
AppState
  └─ reviewSession: ReviewSession?              (new, drives pill like toastMessage)

CapturePipeline                                  (revised)
  ├─ finalizeRecording: on paste success, create session (instead of bare resetIdle)
  └─ refine(_ directive: RefinementDirective)    (new)
      ├─ LLMServing.cleanup(…, refinement:)      (signature extended, nil = today)
      ├─ ClipboardInjecting.replace(old:with:)   (new protocol requirement)
      └─ DictationHistoryStore.updateMostRecent  (new)

RecordingPillWindow                              (revised)
  ├─ ignoresMouseEvents = false only while reviewSession != nil
  └─ keeps position from the thinking phase (no mouse re-chase)

RecordingPillView                                (revised)
  └─ review appearance: [Terser] [Longer] [Clearer] [×], hover pauses expiry
```

Boundaries:

- `ReviewSession` is a plain value; owning/expiring it is `CapturePipeline`'s
  job. The view reads it and calls back; it never mutates the session.
- The injector knows how to swap text, nothing about LLMs or directives.
- `LLMService` treats `refinement` as one more prompt ingredient; providers
  (Anthropic/OpenAI clients) are untouched — the directive is folded into the
  system prompt before the request is built.

## Components

### `ReviewSession` — new

Location: `voxline/Pipeline/ReviewSession.swift` (value type) plus the
`reviewSession: ReviewSession?` property on `AppState`.

```swift
struct ReviewSession: Equatable {
    let transcript: String          // original Whisper output
    let mode: Mode                  // as resolved at dictation time
    let context: CapturedContext    // as captured at dictation time
    var insertedText: String        // exactly what sits in the target field now
    var expiresAt: Date
}
```

Lifecycle rules:

- Created in `finalizeRecording` **only after** `injector.inject` succeeds.
  Error paths never create a session.
- Cleared (set nil) by: expiry, × click, `startRecording` (a new chord press —
  back-to-back dictation is unaffected), and refine's clipboard fallback is the
  one exception: fallback keeps the session so the buttons remain retryable.
- Clearing the session is the scrub: the transcript copy dies with it. This
  preserves the existing hygiene rule that spoken passwords/2FA codes don't
  linger in process memory — the linger window is bounded (~7s idle, reset on
  interaction) instead of "until next dictation".
- Expiry timer runs in `RunLoop.Mode.common` (the `.default`-only-mode stall
  while the menu-bar menu is open is known issue #20; don't add another).
- Hover pauses: view reports hover begin/end; pipeline suspends/reschedules
  the expiry timer accordingly.

Constants: `lingerDuration = 7s`, reset to full on every successful refine and
on hover end.

### `RefinementDirective` — new

```swift
enum RefinementDirective: String, CaseIterable {
    case terser, longer, clearer
}
```

Prompt text (exact strings live next to the enum, snapshot-tested):

- **terser** — "Rewrite to be significantly more concise while preserving the
  full meaning."
- **longer** — "Expand into fuller, more complete sentences; keep the meaning,
  add no new claims."
- **clearer** — "Rewrite for clarity, grammar, and flow — fix awkward phrasing
  without changing the meaning or register."

### `LLMServing.cleanup(transcript:mode:context:refinement:)` — revised

`refinement: RefinementDirective? = nil`. When nil, the built prompt is
byte-identical to today's (snapshot test guards this). When set, the directive
text is appended to the system prompt after the mode prompt, prefixed with a
short framing line ("The user asked for this specific adjustment to the
rewrite:"). Provider clients (`AnthropicClient`, `OpenAIClient`) are unchanged.

### `CapturePipeline.refine(_:)` — new

```swift
func refine(_ directive: RefinementDirective) async
```

- Guards: `state.reviewSession != nil` and `state.status == .idle`; otherwise
  no-op. (`startRecording`'s existing `.thinking` re-entry guard already keeps
  a chord press from racing a refine in flight.)
- Sets `.thinking`, runs cleanup with the session's stored transcript, mode,
  and context. **LLM failure:** show the error as a toast, keep the session
  and the pasted text untouched — the click is retryable.
- On success calls `injector.replace(session.insertedText, with: cleaned)`:
  - **Replaced in place** → update `session.insertedText`, reset expiry,
    `historyStore.updateMostRecent(cleanedText: cleaned)`, back to `.idle`.
  - **Fallback** → new text is already on the clipboard (see injector);
    toast "Copied — ⌘V to replace"; session stays alive; history updates too
    (the user asked for this version; the clipboard holds it).

### `ClipboardInjecting.replace(_ old: String, with new: String)` — new

Implemented in `ClipboardInjector`. Verified selection swap:

1. Read the focused element; bail to fallback if the element identity differs
   from a fresh read mid-flow, if AX is unavailable, or if
   `focusedFieldIsSecure()`.
2. Read the caret position (`kAXSelectedTextRangeAttribute`); set the selected
   range to the `old.utf16.count` units ending at the caret.
3. Read back `kAXSelectedTextAttribute`. **Only if it exactly equals `old`**,
   run the existing paste machinery over the selection (clipboard-paste
   strategy, snapshot/restore as today).
4. Any mismatch or AX error at any step → restore the original selection if
   possible, then fallback: write `new` to the clipboard (no restore — the
   user needs it there) and return `.fallbackClipboard`.

Return type: a small enum (`.replaced(TextInsertionOutcome)` /
`.fallbackClipboard`) so the pipeline can choose the toast. The
verify-before-paste rule is the safety property: the failure mode is "press
⌘V yourself", never "mangled document".

UTF-16 note: AX ranges are UTF-16-unit based; use `old.utf16.count`, not
`old.count` (emoji and non-BMP characters would otherwise shift the range).

### `RecordingPillWindow` / `RecordingPillView` — revised

- `updateVisibility` treats `reviewSession != nil` as a show-state alongside
  recording/thinking/toast.
- `panel.ignoresMouseEvents = (state.reviewSession == nil)` — the pill is
  click-through in every state except review, exactly as today otherwise.
- The panel keeps `.nonactivatingPanel` and the SwiftUI buttons must not
  cause activation (verify no `NSApp.activate` is reachable from the button
  action path; buttons call straight into `CapturePipeline.refine`).
- Position: when transitioning thinking → review the panel does **not**
  reposition to the mouse; it stays where the user is already looking.
- Review layout: three compact text buttons + ×, same visual family as the
  current pill. During an in-flight refine the buttons are replaced by the
  existing thinking spinner.

### `DictationHistoryStore.updateMostRecent(cleanedText:)` — new

Replaces the text of the most recent entry (the one `finalizeRecording` just
recorded). If history is empty (defensive), records a new entry instead.

## Error handling summary

| Failure | Behavior |
|---|---|
| LLM error during refine | Error toast; session and pasted text untouched; buttons retryable |
| AX selection mismatch / unavailable / secure field / focus moved | Clipboard fallback + "Copied — ⌘V to replace" toast; session alive |
| Chord pressed during review | Session scrubbed; normal recording starts |
| Chord pressed during in-flight refine | Rejected by existing `.thinking` guard (unchanged behavior) |
| App quits / pill closed | Session dies with process; nothing persisted beyond history |

## Testing

Swift Testing (`@Suite` / `@Test` / `#expect`), matching existing suites:

1. **Session lifecycle** — created only on paste success; cleared on expiry,
   ×, and `startRecording`; kept on clipboard fallback; transcript scrub
   verified (session nil ⇒ no transcript copy retained).
2. **Prompt assembly** — snapshot: `refinement == nil` produces today's exact
   prompt; each directive appends its text once, after the mode prompt.
3. **Replace verification** — against a fake `FocusedTextSystem`: exact match
   → replaced; mismatch, secure field, identity change, AX failure → fallback;
   UTF-16 range math with emoji in `old`.
4. **Pipeline refine** — fake LLM/injector: success updates `insertedText`,
   resets expiry, updates history; LLM failure keeps session; guard no-ops
   when session nil or status ≠ idle.
5. **Pill visibility/interactivity matrix** — review state shows panel and
   enables mouse events; all other states remain click-through.

Manual verification (no automated harness for cross-app AX): TextEdit, Notes,
Slack, a terminal, and Google Docs in Chrome — expect in-place replace in the
first three, clipboard fallback in the last two, and focus never leaving the
target app.
