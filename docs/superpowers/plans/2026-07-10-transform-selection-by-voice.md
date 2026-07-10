# Transform Selection by Voice — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user highlight text in any app, press the dictation hotkey, speak a rewrite/restructure command (e.g. "make this cleaner," "turn this into bullet points"), and have Voxline transform the selection in place.

**Architecture:** When recording starts, snapshot the focused app's selected text (a new, larger-cap AX read) alongside the existing context probe. In `finalizeRecording`, if that snapshot is non-empty, treat the transcribed speech as a *command* and route it through a new instruction-following LLM path (`LLMService.transform`) with the selection as payload, then paste the result over the still-live selection and open a review session. If nothing was selected, the existing dictation path runs unchanged. The review pill's Shorter/Longer/Clearer buttons chain on the transformed text via a `kind` discriminator on `ReviewSession`.

**Tech Stack:** Swift, macOS AppKit, Accessibility (AX) APIs, Swift Testing (`import Testing`), Anthropic/OpenAI HTTP clients.

## Global Constraints

- Module name is `voxline`; tests use `@testable import voxline`.
- Test framework is **Swift Testing** (`@Suite`/`@Test`/`#expect`/`Issue.record`), NOT XCTest.
- Run tests with:
  ```bash
  xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS'
  ```
- Secure fields must never be read or written (the selection reader returns nil for them; `ClipboardInjector.inject` already blocks them).
- Spoken content can be sensitive — do not retain selection text longer than needed; null out the selection task after use (handled by the existing `cancelContextTask` cleanup point and the post-await clear).
- Follow existing patterns: hand-written fakes conforming to the injected protocols, per-test `UserDefaults(suiteName:)`.

---

## File Structure

**New files:**
- `voxline/Context/SelectionSnapshot.swift` — `SelectionSnapshotting` protocol + `DefaultSelectionSnapshot` (full-selection AX read, larger cap, secure-field guard).

**Modified files:**
- `voxline/LLM/LLMProvider.swift` — make `LLMRequest.maxOutputTokens` overridable.
- `voxline/Pipeline/PipelineProtocols.swift` — add `transform(...)` to `LLMServing`.
- `voxline/LLM/LLMService.swift` — add `transformPreamble` + `transform(instruction:selection:mode:)`.
- `voxline/Pipeline/ReviewSession.swift` — add `ReviewKind` + `kind` field.
- `voxline/Pipeline/CapturePipeline.swift` — inject the selection reader, snapshot at record-start, branch in `finalizeRecording`, add `performTransform`, thread `kind` through `startReviewSession`, and branch `refine` on `kind`.

**Modified tests:**
- `voxlineTests/LLMServiceTests.swift` — transform routing/body/max-tokens/no-key/empty-selection tests.
- `voxlineTests/CapturePipelineTests.swift` — extend `FakeLLM` + `FakeInjector` usage, add `FakeSelectionSnapshot`, update helpers to inject a deterministic selection reader, add `makeTransformPipeline`, add transform-branch and refine-on-transform tests.

No production wiring change is required in `voxlineApp.swift`: the new `selectionSnapshot` init parameter has a default of `DefaultSelectionSnapshot()`.

---

## Task 1: Transform LLM path

Adds a second, instruction-following LLM entry point. Because it extends the `LLMServing` protocol, the same task must implement the method on both `LLMService` (real) and `FakeLLM` (test) or the test target won't compile.

**Files:**
- Modify: `voxline/LLM/LLMProvider.swift:35`
- Modify: `voxline/Pipeline/PipelineProtocols.swift:36-41`
- Modify: `voxline/LLM/LLMService.swift` (add static `transformPreamble` near line 61; add `transform` method after `cleanup`, ~line 163)
- Modify: `voxlineTests/CapturePipelineTests.swift:35-47` (extend `FakeLLM`)
- Test: `voxlineTests/LLMServiceTests.swift`

**Interfaces:**
- Produces: `LLMServing.transform(instruction: String, selection: String, mode: Mode) async throws -> String`. Returns the rewritten text; returns the original `selection` unchanged when `selection` is blank; throws `LLMError` on provider/key failure. Uses a 4096 `max_tokens` budget.
- Produces: `LLMService.transformPreamble: String` (static).
- Consumes: existing `LLMRequest`, `KeychainAccount.anthropic/.openai`, `AnthropicClient`/`OpenAIClient`, `AppLog.llm`.

- [ ] **Step 1: Write the failing tests**

Add to `voxlineTests/LLMServiceTests.swift` inside the `LLMServiceTests` suite:

```swift
    @Test func transform_routes_to_anthropic_with_instruction_and_higher_max_tokens() async throws {
        let mock = MockHTTPClient()
        mock.stubResponse = (
            data: #"{"content":[{"type":"text","text":"rewritten"}]}"#.data(using: .utf8)!,
            status: 200
        )
        var settings = AppSettings(defaults: defaultsSuite())
        settings.llmProvider = .anthropic
        let kc = InMemoryKeychain()
        try kc.set("sk-ant", forKey: KeychainAccount.anthropic)

        let service = LLMService(settings: settings, keychain: kc, http: mock)
        let mode = Mode(bundleID: "*", displayName: "d", prompt: "ignored-for-transform", model: nil, temperature: nil)

        let out = try await service.transform(instruction: "make it formal", selection: "hey whats up", mode: mode)
        #expect(out == "rewritten")
        #expect(mock.capturedRequest?.url?.host == "api.anthropic.com")

        let body = try JSONSerialization.jsonObject(with: try #require(mock.capturedRequest?.httpBody)) as! [String: Any]
        // Transform uses its own preamble, NOT the transcription post-processor prompt.
        let system = try #require(body["system"] as? String)
        #expect(system.contains(LLMService.transformPreamble))
        #expect(!system.contains(LLMService.transcriptionPreamble))
        // The spoken command and the selection both reach the model.
        let bodyString = String(data: try #require(mock.capturedRequest?.httpBody), encoding: .utf8) ?? ""
        #expect(bodyString.contains("make it formal"))
        #expect(bodyString.contains("hey whats up"))
        // Larger output budget than the 1024 cleanup default.
        #expect((body["max_tokens"] as? Int) == 4096)
    }

    @Test func transform_with_no_key_throws_missingAPIKey() async throws {
        let mock = MockHTTPClient()
        var settings = AppSettings(defaults: defaultsSuite())
        settings.llmProvider = .anthropic
        let service = LLMService(settings: settings, keychain: InMemoryKeychain(), http: mock)
        let mode = Mode(bundleID: "*", displayName: "d", prompt: "S", model: nil, temperature: nil)
        do {
            _ = try await service.transform(instruction: "make it formal", selection: "hi", mode: mode)
            Issue.record("expected throw")
        } catch let e as LLMError {
            #expect(e == .missingAPIKey)
        }
    }

    @Test func transform_blank_selection_short_circuits_without_http() async throws {
        let mock = MockHTTPClient()
        var settings = AppSettings(defaults: defaultsSuite())
        settings.llmProvider = .anthropic
        let kc = InMemoryKeychain()
        try kc.set("k", forKey: KeychainAccount.anthropic)
        let service = LLMService(settings: settings, keychain: kc, http: mock)
        let mode = Mode(bundleID: "*", displayName: "d", prompt: "S", model: nil, temperature: nil)

        let out = try await service.transform(instruction: "make it formal", selection: "   \n ", mode: mode)
        #expect(out == "   \n ")
        #expect(mock.capturedRequest == nil)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/LLMServiceTests`
Expected: **compile failure** — `value of type 'LLMService' has no member 'transform'` and `has no member 'transformPreamble'`. (The whole test target fails to build because `LLMServing` doesn't yet declare `transform`; that is the expected red state.)

- [ ] **Step 3: Make `LLMRequest.maxOutputTokens` overridable**

In `voxline/LLM/LLMProvider.swift`, change line 35 from:

```swift
    let maxOutputTokens: Int = 1024
```

to:

```swift
    var maxOutputTokens: Int = 1024
```

(Changing `let` to `var` adds `maxOutputTokens` to the synthesized memberwise initializer as a defaulted parameter. Existing `LLMRequest(model:systemPrompt:userPrompt:temperature:)` call sites keep compiling and still get 1024.)

- [ ] **Step 4: Add `transform` to the `LLMServing` protocol**

In `voxline/Pipeline/PipelineProtocols.swift`, replace the `LLMServing` protocol (lines 36-41):

```swift
protocol LLMServing: Sendable {
    func cleanup(transcript: String, mode: Mode, context: CapturedContext, refinement: RefinementDirective?) async throws -> String
    func transform(instruction: String, selection: String, mode: Mode) async throws -> String
}
```

- [ ] **Step 5: Add the transform preamble and method to `LLMService`**

In `voxline/LLM/LLMService.swift`, add this static constant right after the `transcriptionPreamble` declaration (after line 61):

```swift
    /// System prompt for the "transform selection by voice" path. Unlike
    /// `transcriptionPreamble` — which forbids acting on the input — this
    /// prompt is meant to OBEY the user's spoken instruction, constrained to
    /// rewriting and restructuring the provided text.
    static let transformPreamble = """
    You are a text-editing assistant. The user selected a passage of text and \
    spoke an instruction for changing it. Apply the instruction and return only \
    the resulting text — no greeting, preface, commentary, quotes, or markdown \
    fences.

    Rules:
    - Rewrite and restructure only. You may change wording, tone, length, \
    grammar, and formatting (for example, turn prose into bullet points or a \
    numbered list).
    - Preserve the original meaning and every fact. Add no new information.
    - Do not translate the text into another language.
    - If the instruction cannot be carried out as a rewrite or restructuring of \
    the provided text (for example: translate it, summarize with new content, \
    or answer a question it poses), return the original text unchanged.
    """
```

Then add the `transform` method after `cleanup` (after line 163, before the closing brace of the struct):

```swift
    func transform(instruction: String, selection: String, mode: Mode) async throws -> String {
        // Blank selection → nothing to transform. Return it verbatim so callers
        // can detect "unchanged" without a network round-trip.
        guard !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return selection
        }

        // Provider/key/client resolution mirrors `cleanup`. Kept inline rather
        // than shared to avoid disturbing cleanup's DEBUG trace, which needs
        // the provider/model locals.
        let provider = settings.llmProvider
        let account: String
        switch provider {
        case .anthropic: account = KeychainAccount.anthropic
        case .openai:    account = KeychainAccount.openai
        }
        guard
            let key = try keychain.string(forKey: account),
            !key.isEmpty
        else {
            AppLog.llm.error("\(provider.rawValue): no API key configured")
            throw LLMError.missingAPIKey
        }

        let model = mode.model ?? settings.llmModel
        let userPrompt = "Instruction: \(instruction)\n\nText:\n\(selection)"
        let request = LLMRequest(
            model: model,
            systemPrompt: Self.transformPreamble,
            userPrompt: userPrompt,
            temperature: mode.temperature,
            maxOutputTokens: 4096
        )

        let client: any LLMClient
        switch provider {
        case .anthropic: client = AnthropicClient(apiKey: key, http: http)
        case .openai:    client = OpenAIClient(apiKey: key, http: http)
        }
        return try await client.cleanup(request)
    }
```

- [ ] **Step 6: Implement `transform` on `FakeLLM`**

In `voxlineTests/CapturePipelineTests.swift`, extend `FakeLLM` (lines 35-47) so the test target compiles. Replace the class body with:

```swift
    final class FakeLLM: LLMServing, @unchecked Sendable {
        var nextResult: Result<String, Error> = .success("cleaned")
        var calls: [(transcript: String, mode: Mode, context: CapturedContext, refinement: RefinementDirective?)] = []
        var transformResult: Result<String, Error> = .success("transformed")
        var transformCalls: [(instruction: String, selection: String, mode: Mode)] = []
        /// Invoked during `cleanup`/`transform`, after the call is recorded and
        /// before the result is returned — lets tests simulate MainActor
        /// reentrancy (e.g. the review session being dismissed mid-flight).
        var onCleanup: (() -> Void)? = nil
        func cleanup(transcript: String, mode: Mode, context: CapturedContext, refinement: RefinementDirective?) async throws -> String {
            calls.append((transcript, mode, context, refinement))
            onCleanup?()
            return try nextResult.get()
        }
        func transform(instruction: String, selection: String, mode: Mode) async throws -> String {
            transformCalls.append((instruction, selection, mode))
            onCleanup?()
            return try transformResult.get()
        }
    }
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/LLMServiceTests`
Expected: PASS (all three new tests plus the existing cleanup tests).

- [ ] **Step 8: Commit**

```bash
git add voxline/LLM/LLMProvider.swift voxline/Pipeline/PipelineProtocols.swift voxline/LLM/LLMService.swift voxlineTests/CapturePipelineTests.swift voxlineTests/LLMServiceTests.swift
git commit -m "feat(llm): add instruction-following transform() path

Second LLM entry point that obeys a spoken command over a supplied
selection, constrained to rewrite/restructure. Overridable max_tokens.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Full-selection reader

A dedicated AX reader that returns the *entire* current selection (up to a generous cap) as the transform payload, distinct from the 500-char context-probe sample. Returns nil for secure fields.

**Files:**
- Create: `voxline/Context/SelectionSnapshot.swift`
- Test: `voxlineTests/SelectionSnapshotTests.swift`

**Interfaces:**
- Produces: `protocol SelectionSnapshotting: Sendable { func readSelection() -> String? }`.
- Produces: `struct DefaultSelectionSnapshot: SelectionSnapshotting` with `static let selectionMax = 8_000` and `static func cap(_ s: String) -> String`.
- Consumes: `AXUIElement.systemWideFocusedElement()` and `.stringAttribute(_:)` from `voxline/Util/AXAttributeReading.swift`; `AXIsProcessTrusted()`; `kAXSelectedTextAttribute`, `kAXSubroleAttribute`, `kAXSecureTextFieldSubrole`.

Note: the live AX read cannot be unit-tested in CI (no trusted AX process), so the test covers the pure cap logic. The reader is exercised end-to-end through the pipeline in Task 3 via `FakeSelectionSnapshot`.

- [ ] **Step 1: Write the failing test**

Create `voxlineTests/SelectionSnapshotTests.swift`:

```swift
import Testing
import Foundation
@testable import voxline

@Suite struct SelectionSnapshotTests {
    @Test func cap_returns_short_strings_unchanged() {
        #expect(DefaultSelectionSnapshot.cap("hello") == "hello")
    }

    @Test func cap_truncates_to_selectionMax() {
        let long = String(repeating: "a", count: DefaultSelectionSnapshot.selectionMax + 500)
        let capped = DefaultSelectionSnapshot.cap(long)
        #expect(capped.count == DefaultSelectionSnapshot.selectionMax)
    }

    @Test func cap_keeps_exactly_max_length() {
        let exact = String(repeating: "b", count: DefaultSelectionSnapshot.selectionMax)
        #expect(DefaultSelectionSnapshot.cap(exact) == exact)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/SelectionSnapshotTests`
Expected: **compile failure** — `cannot find 'DefaultSelectionSnapshot' in scope`.

- [ ] **Step 3: Create the reader**

Create `voxline/Context/SelectionSnapshot.swift`:

```swift
import ApplicationServices
import Foundation

/// Reads the FULL current selection from the frontmost app's focused element,
/// for the "transform selection by voice" path. Distinct from the context
/// probe: it returns the whole selection (up to a generous cap) as the primary
/// payload to rewrite — not a 500-char background sample — and returns nil in
/// secure fields so a password selection is never sent to the LLM.
protocol SelectionSnapshotting: Sendable {
    func readSelection() -> String?
}

struct DefaultSelectionSnapshot: SelectionSnapshotting {
    /// Generous ceiling so whole paragraphs transform, while bounding a runaway
    /// read (and the LLM request that follows it).
    static let selectionMax = 8_000

    /// Truncate to `selectionMax` characters. Pure so it is unit-testable
    /// without an AX round-trip.
    static func cap(_ s: String) -> String {
        s.count > selectionMax ? String(s.prefix(selectionMax)) : s
    }

    func readSelection() -> String? {
        guard AXIsProcessTrusted() else { return nil }
        guard let focused = AXUIElement.systemWideFocusedElement() else { return nil }
        // Never read a secure field's contents.
        if focused.stringAttribute(kAXSubroleAttribute) == (kAXSecureTextFieldSubrole as String) {
            return nil
        }
        guard
            let selected = focused.stringAttribute(kAXSelectedTextAttribute),
            !selected.isEmpty
        else {
            return nil
        }
        return Self.cap(selected)
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/SelectionSnapshotTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add voxline/Context/SelectionSnapshot.swift voxlineTests/SelectionSnapshotTests.swift
git commit -m "feat(context): add full-selection AX reader for transform path

Reads the entire current selection (up to an 8k cap) as the transform
payload; returns nil for secure fields.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Selection-detection branch + `performTransform`

Wires the reader into the pipeline: snapshot the selection at record-start, and in `finalizeRecording` route non-empty selections through `performTransform` (transform → paste over live selection → transform review session). Adds `ReviewKind` and threads it through `startReviewSession`. Leaves `refine` on its current dictation-only behavior (Task 4 fixes refine for transform sessions).

**Files:**
- Modify: `voxline/Pipeline/ReviewSession.swift:13-19`
- Modify: `voxline/Pipeline/CapturePipeline.swift` (properties ~18-22; init ~38-63; `startRecording` ~122-125; `finalizeRecording` ~202-232; `startReviewSession` ~306-312; `cancelContextTask` ~336-339; add `performTransform`)
- Modify: `voxlineTests/CapturePipelineTests.swift` (add `FakeSelectionSnapshot`; update `makePipeline`, `makePipelineWithContext`, `makeRefinePipeline` to inject it; add `makeTransformPipeline`; add tests)

**Interfaces:**
- Consumes: `SelectionSnapshotting` (Task 2), `LLMServing.transform` (Task 1), existing `injector.inject`, `historyStore.record`, `transcriptFallback`, `showToast`, `resetIdle`, `setError`.
- Produces: `enum ReviewKind: Equatable, Sendable { case dictation, transform }`; `ReviewSession.kind: ReviewKind`; `CapturePipeline.init(..., selectionSnapshot: SelectionSnapshotting = DefaultSelectionSnapshot(), ...)`; `startReviewSession(kind:transcript:mode:context:insertedText:)`; `performTransform(command:selection:mode:context:)`.

- [ ] **Step 1: Add `kind` to `ReviewSession`**

In `voxline/Pipeline/ReviewSession.swift`, replace the struct (lines 13-19) with:

```swift
/// Whether the active review was produced by dictation or by transforming a
/// selection — determines what the Shorter/Longer/Clearer buttons act on.
enum ReviewKind: Equatable, Sendable {
    case dictation
    case transform
}

struct ReviewSession: Equatable, Sendable {
    let kind: ReviewKind
    let transcript: String
    let mode: Mode
    let context: CapturedContext
    var insertedText: String
    var expiresAt: Date
}
```

- [ ] **Step 2: Add the selection reader dependency and record-start snapshot**

In `voxline/Pipeline/CapturePipeline.swift`, add two stored properties after `contextTask` (after line 19):

```swift
    private let selectionSnapshot: SelectionSnapshotting
    private var selectionTask: Task<String?, Never>?
```

Add the init parameter after `contextCapture: ContextCapturing,` (line 48):

```swift
        selectionSnapshot: SelectionSnapshotting = DefaultSelectionSnapshot(),
```

Add the assignment after `self.contextCapture = contextCapture` (line 61):

```swift
        self.selectionSnapshot = selectionSnapshot
```

In `startRecording`, kick off the snapshot right after the context task (after line 125, inside `startRecording`, before the closing brace at 126):

```swift
        let snapshotter = selectionSnapshot
        selectionTask = Task.detached(priority: .userInitiated) {
            snapshotter.readSelection()
        }
```

Update `cancelContextTask` (lines 336-339) to also clear the selection task:

```swift
    private func cancelContextTask() {
        contextTask?.cancel()
        contextTask = nil
        selectionTask?.cancel()
        selectionTask = nil
    }
```

- [ ] **Step 3: Branch `finalizeRecording` and thread `kind` into the dictation review**

In `voxline/Pipeline/CapturePipeline.swift`, after the context read (lines 202-203):

```swift
        let context = await contextTask?.value ?? .empty
        contextTask = nil
```

insert the selection read and transform branch:

```swift
        let selection = await selectionTask?.value ?? nil
        selectionTask = nil
        // If text was selected when recording started, treat the speech as a
        // command to transform that selection instead of as dictation.
        if let selection, !selection.isEmpty {
            await performTransform(command: transcript, selection: selection, mode: mode, context: context)
            return
        }
```

Then update the existing dictation `startReviewSession` call (line ~232) to pass the kind:

```swift
        startReviewSession(kind: .dictation, transcript: transcript, mode: mode, context: context, insertedText: cleaned)
```

- [ ] **Step 4: Update `startReviewSession` and add `performTransform`**

Replace `startReviewSession` (lines 306-312) with the `kind`-carrying version:

```swift
    private func startReviewSession(kind: ReviewKind, transcript: String, mode: Mode, context: CapturedContext, insertedText: String) {
        state.reviewSession = ReviewSession(
            kind: kind, transcript: transcript, mode: mode, context: context,
            insertedText: insertedText, expiresAt: now().addingTimeInterval(reviewLingerDuration)
        )
        scheduleReviewExpiry()
    }
```

Add `performTransform` (place it right after `finalizeRecording`, before `dismissReview`):

```swift
    /// Rewrite the user's selection according to the spoken command, paste it
    /// over the (still-live) selection, and open a transform review session.
    /// Owns its terminal state — callers must not call `resetIdle` afterward.
    private func performTransform(command: String, selection: String, mode: Mode, context: CapturedContext) async {
        let transformed: String
        do {
            transformed = try await llm.transform(instruction: command, selection: selection, mode: mode)
        } catch let e as LLMError {
            return setError("\(e.errorDescription ?? "Transform failed.") Your selection was left unchanged.")
        } catch {
            return setError("Transform failed: \(error.localizedDescription) Your selection was left unchanged.")
        }

        // The transform prompt returns the selection verbatim when the command
        // can't be applied as a rewrite/restructure (e.g. a translate request).
        // Treat that as a no-op rather than re-pasting identical text.
        guard !transformed.isEmpty, transformed != selection else {
            resetIdle()
            showToast("Couldn't apply that")
            return
        }

        historyStore.record(cleanedText: transformed, mode: mode, context: context)

        do {
            // Selection is live, so a paste lands over it — no re-selection needed.
            _ = try await injector.inject(transformed)
        } catch {
            // Any insertion failure: leave the result on the clipboard so ⌘V
            // still replaces the selection.
            transcriptFallback(transformed)
            startReviewSession(kind: .transform, transcript: command, mode: mode, context: context, insertedText: transformed)
            resetIdle()
            showToast("Copied — ⌘V to replace")
            return
        }

        startReviewSession(kind: .transform, transcript: command, mode: mode, context: context, insertedText: transformed)
        resetIdle()
    }
```

- [ ] **Step 5: Add `FakeSelectionSnapshot` and make existing test helpers deterministic**

In `voxlineTests/CapturePipelineTests.swift`, add a fake next to the others (after `FakeInjector`, ~line 73):

```swift
    final class FakeSelectionSnapshot: SelectionSnapshotting, @unchecked Sendable {
        var selection: String?
        func readSelection() -> String? { selection }
    }
```

Inject it (defaulting to `nil` → dictation path) into all three existing pipeline builders so tests never read a real selection on a dev machine with AX granted. In `makePipeline` add `selectionSnapshot: FakeSelectionSnapshot()` to the `CapturePipeline(...)` call (after `contextCapture: FakeContextCapture()`, line 107):

```swift
        let pipe = CapturePipeline(
            state: state, capture: capture, transcriber: transcriber,
            llm: llm, modes: router, frontmost: front,
            fieldInspector: inspector, injector: injector,
            historyStore: history, contextCapture: FakeContextCapture(),
            selectionSnapshot: FakeSelectionSnapshot()
        )
```

In `makePipelineWithContext` add the same argument to its `CapturePipeline(...)` call (after `contextCapture: ctx`, line 129):

```swift
        let pipe = CapturePipeline(
            state: state, capture: capture, transcriber: transcriber,
            llm: llm, modes: router, frontmost: front,
            fieldInspector: inspector, injector: injector,
            historyStore: history, contextCapture: ctx,
            selectionSnapshot: FakeSelectionSnapshot()
        )
```

In `makeRefinePipeline` add the same argument to its `CapturePipeline(...)` call (after `contextCapture: FakeContextCapture(),`, line 504) — note this call also passes `reviewLingerDuration:`/`now:`:

```swift
        let pipe = CapturePipeline(
            state: state, capture: capture, transcriber: transcriber,
            llm: llm, modes: router, frontmost: front,
            fieldInspector: inspector, injector: injector,
            historyStore: history, contextCapture: FakeContextCapture(),
            selectionSnapshot: FakeSelectionSnapshot(),
            reviewLingerDuration: linger, now: { now }
        )
```

- [ ] **Step 6: Add the `makeTransformPipeline` helper**

In `voxlineTests/CapturePipelineTests.swift`, add next to `makeRefinePipeline`:

```swift
    private func makeTransformPipeline(
        selection: String,
        now: Date = Date(timeIntervalSince1970: 10_000),
        linger: TimeInterval = 7
    ) -> (CapturePipeline, AppState, FakeLLM, FakeInjector, DictationHistoryStore) {
        let state = AppState()
        let capture = FakeCapture()
        let transcriber = FakeTranscriber()
        let llm = FakeLLM()
        let front = FakeFrontmost(); front.bundleID = "com.tinyspeck.slackmacgap"
        let inspector = FakeFieldInspector()
        let injector = FakeInjector()
        let snap = FakeSelectionSnapshot(); snap.selection = selection
        let router = ModeRouter(modes: [
            Mode(bundleID: "com.tinyspeck.slackmacgap", displayName: "Slack", prompt: "slack-prompt", model: nil, temperature: nil, category: .chat),
            Mode(bundleID: "*", displayName: "Default", prompt: "default-prompt", model: nil, temperature: nil, category: .general)
        ])
        let name = "voxline-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let history = DictationHistoryStore(defaults: defaults)
        let pipe = CapturePipeline(
            state: state, capture: capture, transcriber: transcriber,
            llm: llm, modes: router, frontmost: front,
            fieldInspector: inspector, injector: injector,
            historyStore: history, contextCapture: FakeContextCapture(),
            selectionSnapshot: snap,
            reviewLingerDuration: linger, now: { now }
        )
        return (pipe, state, llm, injector, history)
    }
```

- [ ] **Step 7: Write the failing transform-branch tests**

Add to the `CapturePipelineTests` suite (near the refine tests). `FakeTranscriber`'s default output is `"hello world"`, which stands in for the spoken command:

```swift
    @Test func finalize_withSelection_transformsAndOpensTransformReview() async {
        let (pipe, state, llm, injector, history) = makeTransformPipeline(selection: "original text")
        pipe.startRecording(); state.lastPeakLevel = 0.5; await pipe.finalizeRecording()

        #expect(llm.transformCalls.last?.selection == "original text")
        #expect(llm.transformCalls.last?.instruction == "hello world")   // the spoken command
        #expect(llm.calls.isEmpty)                                       // dictation cleanup NOT called
        #expect(injector.injected.last == "transformed")                 // pasted over the live selection
        #expect(injector.replaceCalls.isEmpty)                           // initial transform uses inject, not replace
        #expect(history.items.first?.cleanedText == "transformed")
        #expect(state.reviewSession?.kind == .transform)
        #expect(state.reviewSession?.insertedText == "transformed")
        if case .idle = state.status {} else { Issue.record("expected .idle after transform") }
    }

    @Test func finalize_withSelection_unchangedResult_showsToastNoWrite() async {
        let (pipe, state, llm, injector, history) = makeTransformPipeline(selection: "original text")
        llm.transformResult = .success("original text")   // model declined → returned selection verbatim
        pipe.startRecording(); state.lastPeakLevel = 0.5; await pipe.finalizeRecording()

        #expect(injector.injected.isEmpty)
        #expect(history.items.isEmpty)
        #expect(state.reviewSession == nil)
        #expect(state.toastMessage == "Couldn't apply that")
        if case .idle = state.status {} else { Issue.record("expected .idle") }
    }

    @Test func finalize_withSelection_llmError_setsError() async {
        let (pipe, state, llm, injector, _) = makeTransformPipeline(selection: "original text")
        llm.transformResult = .failure(LLMError.missingAPIKey)
        pipe.startRecording(); state.lastPeakLevel = 0.5; await pipe.finalizeRecording()

        #expect(injector.injected.isEmpty)
        #expect(state.reviewSession == nil)
        if case .error = state.status {} else { Issue.record("expected .error status") }
    }

    @Test func finalize_withSelection_injectFails_fallsBackToClipboard() async {
        let (pipe, state, _, injector, _) = makeTransformPipeline(selection: "original text")
        injector.nextError = TextInsertionError.pasteVerificationFailed
        var fallbackText: String?
        pipe.transcriptFallback = { fallbackText = $0 }   // capture instead of touching NSPasteboard.general
        pipe.startRecording(); state.lastPeakLevel = 0.5; await pipe.finalizeRecording()

        #expect(fallbackText == "transformed")
        #expect(state.toastMessage == "Copied — ⌘V to replace")
        #expect(state.reviewSession?.kind == .transform)
        #expect(state.reviewSession?.insertedText == "transformed")
    }

    @Test func finalize_withEmptySelection_usesDictationPath() async {
        let (pipe, state, llm, injector, _) = makeTransformPipeline(selection: "")
        pipe.startRecording(); state.lastPeakLevel = 0.5; await pipe.finalizeRecording()

        #expect(llm.transformCalls.isEmpty)
        #expect(llm.calls.count == 1)                    // dictation cleanup called
        #expect(injector.injected.last == "cleaned")
        #expect(state.reviewSession?.kind == .dictation)
    }
```

- [ ] **Step 8: Run the tests to verify they fail, then pass after implementation**

Run: `xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/CapturePipelineTests`
Expected before implementing Steps 1-4: **compile failure** (`extra argument 'selectionSnapshot'`, `has no member 'kind'`). After Steps 1-6 are applied: all tests PASS, including the pre-existing dictation and refine tests (whose `startReviewSession` now yields `.dictation`).

- [ ] **Step 9: Commit**

```bash
git add voxline/Pipeline/ReviewSession.swift voxline/Pipeline/CapturePipeline.swift voxlineTests/CapturePipelineTests.swift
git commit -m "feat(pipeline): route selection+speech to transform, paste over selection

Snapshot the selection at record-start; when non-empty, treat speech as a
transform command, paste the rewrite over the live selection, and open a
transform-kind review session. Empty selection keeps today's dictation path.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Refine chaining on transformed text

Make the pill's Shorter/Longer/Clearer buttons operate on the *transformed* text for transform sessions (via `llm.transform` with the directive's prompt as the instruction), while keeping dictation refine unchanged. No UI change is needed — the buttons already call `pipeline.refine(directive)`.

**Files:**
- Modify: `voxline/Pipeline/CapturePipeline.swift` (`refine`, lines 240-279)
- Test: `voxlineTests/CapturePipelineTests.swift`

**Interfaces:**
- Consumes: `ReviewSession.kind` (Task 3), `LLMServing.transform` (Task 1), `RefinementDirective.promptText`.
- Behavior: for `.transform` sessions, `refine` calls `llm.transform(instruction: directive.promptText, selection: session.insertedText, mode: session.mode)`; the replace/history/session-update path is identical to dictation refine.

- [ ] **Step 1: Write the failing test**

Add to the `CapturePipelineTests` suite:

```swift
    @Test func refine_onTransformSession_usesTransformOnCurrentText() async {
        let (pipe, state, llm, injector, history) = makeTransformPipeline(selection: "original text")
        pipe.startRecording(); state.lastPeakLevel = 0.5; await pipe.finalizeRecording()
        #expect(state.reviewSession?.kind == .transform)

        llm.transformResult = .success("tighter")
        await pipe.refine(.terser)

        #expect(llm.transformCalls.last?.instruction == RefinementDirective.terser.promptText)
        #expect(llm.transformCalls.last?.selection == "transformed")   // acts on current inserted text, not the command
        #expect(llm.calls.isEmpty)                                     // cleanup never used for a transform session
        #expect(injector.replaceCalls.last?.old == "transformed")
        #expect(injector.replaceCalls.last?.new == "tighter")
        #expect(state.reviewSession?.insertedText == "tighter")
        #expect(history.items.count == 1)
        #expect(history.items.first?.cleanedText == "tighter")
        if case .idle = state.status {} else { Issue.record("expected .idle after transform refine") }
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/CapturePipelineTests/refine_onTransformSession_usesTransformOnCurrentText`
Expected: FAIL — `llm.transformCalls.last` is nil and `llm.calls` is non-empty, because `refine` currently always calls `cleanup` (using the spoken command as the transcript).

- [ ] **Step 3: Branch `refine` on the session kind**

In `voxline/Pipeline/CapturePipeline.swift`, in `refine` (lines 240-279), replace the LLM-call block:

```swift
        let cleaned: String
        do {
            cleaned = try await llm.cleanup(
                transcript: session.transcript, mode: session.mode,
                context: session.context, refinement: directive
            )
        } catch let e as LLMError {
```

with:

```swift
        let cleaned: String
        do {
            switch session.kind {
            case .dictation:
                cleaned = try await llm.cleanup(
                    transcript: session.transcript, mode: session.mode,
                    context: session.context, refinement: directive
                )
            case .transform:
                // Chain on the current text, applying the directive as the
                // instruction — not a re-run of the original spoken command.
                cleaned = try await llm.transform(
                    instruction: directive.promptText,
                    selection: session.insertedText, mode: session.mode
                )
            }
        } catch let e as LLMError {
```

(Leave the rest of `refine` — the post-await session guard, `injector.replace`, `historyStore.updateMostRecent`, `session.insertedText = cleaned`, fallback toast — unchanged.)

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/CapturePipelineTests`
Expected: PASS — the new transform-refine test plus all existing dictation refine tests (`refine_success_...`, `refine_fallbackClipboard_...`, `refine_llmError_...`, `refine_noSession_...`, `refine_wrongStatus_...`, `refine_sessionDismissedDuringCleanup_...`), which still exercise the `.dictation` branch.

- [ ] **Step 5: Commit**

```bash
git add voxline/Pipeline/CapturePipeline.swift voxlineTests/CapturePipelineTests.swift
git commit -m "feat(pipeline): chain refine buttons on transformed text

For transform sessions, Shorter/Longer/Clearer apply the directive as a
transform instruction over the current text instead of re-cleaning the
spoken command.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Full-suite verification

**Files:** none (verification only).

- [ ] **Step 1: Run the entire test suite**

Run: `xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS'`
Expected: PASS across all suites (no regressions in `CapturePipelineTests`, `LLMServiceTests`, `ContextBlockFormatterTests`, etc.).

- [ ] **Step 2: Manual smoke test (real app, requires Accessibility permission)**

Build/run the app (`scripts/build-local.sh` or Xcode Run). Then:
1. In TextEdit, type a rough sentence, select it, press the dictation hotkey, and say "make this more formal." Expect the selection replaced by a formal rewrite, and the review pill to appear.
2. With the pill up, click **Shorter** — expect the rewrite to tighten further in place.
3. Select a sentence and say "turn this into bullet points" — expect a bulleted rewrite.
4. Select a sentence and say "translate this to Spanish" — expect no change and a "Couldn't apply that" toast (out-of-scope command).
5. With nothing selected, dictate normally — expect unchanged insertion behavior.
6. Try step 1 in an Electron editor (e.g. Obsidian, VS Code) to exercise the paste-over-live-selection path in an AX-hostile editor.

- [ ] **Step 3: Commit any fixes surfaced by the smoke test** (if needed), then the feature is complete.

---

## Self-Review Notes

- **Spec §1 (auto-detect flow):** Task 3 branch on non-empty selection at record-start.
- **Spec §2 (larger selection read):** Task 2 `DefaultSelectionSnapshot` (8k cap), separate from the untouched 500-char context probe; Task 1 raises `max_tokens` to 4096.
- **Spec §3 (new instruction-following prompt):** Task 1 `transformPreamble` + `transform`, guardrailed to rewrite/restructure, no translation/new facts.
- **Spec §4 (write back over live selection + fallback):** Task 3 `performTransform` uses `inject` over the live selection with clipboard-fallback toast.
- **Spec §5 (transform review + refine chains on transformed text):** Task 3 `.transform` review session; Task 4 refine branch.
- **Spec Edge cases:** secure fields (Task 2 nil + inject block), out-of-scope → unchanged + "Couldn't apply that" toast (Task 3), empty/failed command transcription (existing empty-transcript guard in `finalizeRecording` returns before the branch), focus/session lost during LLM (existing post-await guard in `refine`; initial transform re-reads nothing after paste).
- **Deferred (spec Open Questions):** exact cap/token values are set to 8k/4096 here and can be tuned; overwrite-by-dictation escape hatch intentionally omitted.
