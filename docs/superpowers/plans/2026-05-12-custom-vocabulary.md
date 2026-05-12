# Custom Vocabulary Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire the existing global custom-vocabulary list into both transcription (WhisperKit `promptTokens`) and LLM cleanup (preamble-driven canonical-spelling normalization), and replace the stub `TextEditor` settings UI with a real row-based list that enforces the WhisperKit prompt-token budget.

**Architecture:** Two-pass shared list — the same `[String]` from `CustomVocabularyStore` feeds (a) `WhisperPromptBuilder` to produce `DecodingOptions.promptTokens` at transcribe time, and (b) the existing `ContextBlockFormatter` `- Custom vocabulary: ...` line at cleanup time. A revised LLM system preamble paragraph instructs the model to normalize transcript words to the canonical forms. Settings replaces a one-line `TextEditor` with `CustomVocabularyListView`, backed by a view-model that owns add/remove + a live `tokenCount` source.

**Tech Stack:** Swift 6, SwiftUI (`@Observable`), WhisperKit 1.0.0 (argmax-oss-swift), Swift Testing framework (`@Test` / `#expect`), Xcode 16, macOS 15.

**Spec:** `docs/superpowers/specs/2026-05-12-custom-vocabulary-design.md`.

---

## File Structure

**New files:**

- `voxline/Transcription/WhisperPromptBuilder.swift` — pure-function builder that joins terms, tokenizes via an injected `VocabularyTokenizing`, filters special tokens, truncates to budget.
- `voxline/Settings/Components/CustomVocabularyListView.swift` — SwiftUI section view (list rows + Add field + footer).
- `voxline/Settings/Components/CustomVocabularyListViewModel.swift` — `@Observable @MainActor` view-model wrapping `CustomVocabularyStore`, a `TokenCountSource` async closure, and a `whisperModel` binding for invalidation.
- `voxlineTests/WhisperPromptBuilderTests.swift` — six tests against a fake tokenizer.
- `voxlineTests/CustomVocabularyListViewModelTests.swift` — seven tests against a fake count source.

**Modified files:**

- `voxline/Transcription/TranscriptionService.swift` — add `vocabulary:` to `transcribe(samples:)`; add `tokenCount(for terms:)`; add `tokenizerOrNil` accessor for the view-model.
- `voxline/Pipeline/PipelineProtocols.swift` — extend `Transcribing` with `vocabulary:` parameter and `tokenCount`.
- `voxline/Pipeline/CapturePipeline.swift` — accept `CustomVocabularyStore`, load vocab in `finalizeRecording`, pass to `transcriber.transcribe`.
- `voxline/LLM/LLMService.swift` — revise the existing context-rules paragraph in `transcriptionPreamble`.
- `voxline/Settings/SettingsView.swift` — replace the `Section("Custom vocabulary")` block with `CustomVocabularyListView(...)`.
- `voxline/Settings/GeneralSettingsViewModel.swift` — delete `customVocabularyText` property + its didSet; keep `vocabulary: CustomVocabularyStore` for `resetToDefaults`.
- `voxline/Storage/CustomVocabularyStore.swift` — delete the stale "stub for feature #9" doc comment.
- `voxlineTests/TranscriptionServiceTests.swift` — extend existing transcribe tests with `vocabulary: []`; add two new tests for vocab paths (if Whisper-dependent setup makes this impractical, mark as integration-only and rely on `WhisperPromptBuilderTests` for the builder side).
- `voxlineTests/CapturePipelineTests.swift` — extend `FakeTranscriber` to record `vocabulary:`; add one test that asserts the loaded vocab is passed through; thread `CustomVocabularyStore` into `makePipeline`.
- `voxlineTests/GeneralSettingsViewModelTests.swift` — delete the two `customVocabularyText_*` tests; keep `resetToDefaults` coverage.
- `voxlineTests/LLMServiceTests.swift` — add a snapshot-style test on the preamble text (or add `LLMPreambleTests.swift` if the existing file has no relevant slot).

**voxlineTests/voxline.xcodeproj membership:** Whenever a new `.swift` file is created in `voxline/...` or `voxlineTests/...`, it must be added to the corresponding Xcode target. The project file is `voxline.xcodeproj/project.pbxproj`. Steps below use Xcode's "Add Files…" or direct editing — see Task 1 Step 1 for the exact procedure.

---

## Task 1: `WhisperPromptBuilder` (TDD)

**Files:**
- Create: `voxline/Transcription/WhisperPromptBuilder.swift`
- Create: `voxlineTests/WhisperPromptBuilderTests.swift`
- Modify: `voxline.xcodeproj/project.pbxproj` (target membership for the two new files)

- [ ] **Step 1: Create the test file with the first failing test**

Create `voxlineTests/WhisperPromptBuilderTests.swift` with this content:

```swift
import Testing
import Foundation
@testable import voxline

/// Tests for WhisperPromptBuilder. Uses a fake tokenizer so the suite has no
/// dependency on WhisperKit weights — each character maps to a deterministic
/// token ID, and `,` plus ` ` are given dedicated IDs so we can assert
/// joining behavior precisely.
@Suite struct WhisperPromptBuilderTests {

    /// Deterministic fake. Each Character maps to its Unicode scalar value
    /// as the token ID. Unrecognized strings tokenize to nothing. Special-
    /// token threshold is 50000 so any ID below that is a "normal" token.
    struct FakeTokenizer: VocabularyTokenizing {
        var specialTokenBegin: Int = 50_000
        /// Optional override: terms whose tokenization should include a
        /// special-token ID. Maps a term to the IDs it should produce.
        var overrides: [String: [Int]] = [:]
        func encode(text: String) -> [Int] {
            if let override = overrides[text] { return override }
            return text.unicodeScalars.map { Int($0.value) }
        }
    }

    @Test func promptString_joins_terms_with_comma_space_and_trailing_period() {
        let s = WhisperPromptBuilder.promptString(from: ["Argmax", "LangGraph", "MSL"])
        #expect(s == "Argmax, LangGraph, MSL.")
    }

    @Test func promptString_returns_empty_when_no_terms() {
        let s = WhisperPromptBuilder.promptString(from: [])
        #expect(s == "")
    }

    @Test func promptTokens_returns_empty_when_no_terms() {
        let tokens = WhisperPromptBuilder.promptTokens(from: [], tokenizer: FakeTokenizer())
        #expect(tokens.isEmpty)
    }

    @Test func promptTokens_truncates_from_tail_when_over_budget() {
        // Each ASCII term encodes to N tokens (1 per character). "AAAA" → 4
        // tokens. With budget=6 and ["AAA", "BBB", "CCC"] (joined as
        // "AAA, BBB, CCC.") that's 3 + 2 + 3 + 2 + 3 + 1 = 14 tokens — but
        // we only ever look at the per-term encoding plus joiner cost when
        // truncating. The builder rebuilds the prompt with the first N
        // terms that fit. With budget=10 and three 3-char terms + 2-char
        // joiners: "AAA, BBB" → 8 tokens including the trailing ".". Add
        // "CCC" pushes to 13 → drop it.
        let tokens = WhisperPromptBuilder.promptTokens(
            from: ["AAA", "BBB", "CCC"],
            tokenizer: FakeTokenizer(),
            budget: 10
        )
        // Expect tokens for "AAA, BBB." (kept the first two, dropped the
        // last). Per-char ASCII values: 'A'=65, ','=44, ' '=32, 'B'=66,
        // '.'=46. So: [65,65,65,44,32,66,66,66,46]. 9 tokens, fits in 10.
        #expect(tokens == [65, 65, 65, 44, 32, 66, 66, 66, 46])
    }

    @Test func promptTokens_filters_special_token_ids() {
        // "Argmax" override emits one special-token ID (99999) and two
        // normals. Builder must drop the 99999.
        var t = FakeTokenizer()
        t.overrides["Argmax"] = [99_999, 65, 66]
        let tokens = WhisperPromptBuilder.promptTokens(from: ["Argmax"], tokenizer: t, budget: 100)
        #expect(!tokens.contains(99_999))
        #expect(tokens.contains(65))
        #expect(tokens.contains(66))
    }

    @Test func tokenCount_matches_promptTokens_length_when_under_budget() {
        let t = FakeTokenizer()
        let terms = ["Argmax", "MSL"]
        let count = WhisperPromptBuilder.tokenCount(of: terms, tokenizer: t)
        let tokens = WhisperPromptBuilder.promptTokens(from: terms, tokenizer: t, budget: 1_000)
        #expect(count == tokens.count)
    }
}
```

- [ ] **Step 2: Add the test file to the `voxlineTests` Xcode target**

The project file is large; the safest path is to use Xcode itself: open `voxline.xcodeproj`, right-click the `voxlineTests` group, choose **Add Files to "voxline"…**, select `voxlineTests/WhisperPromptBuilderTests.swift`, confirm the **voxlineTests** target is checked, and save. If editing the `.pbxproj` directly, mirror the surrounding entries for `CustomVocabularyStoreTests.swift` (a similar test-only file) — add a `PBXFileReference`, a `PBXBuildFile` for it, and a reference in the test target's `PBXSourcesBuildPhase`.

Verify by opening the project and confirming the file appears under `voxlineTests` in the navigator with the test target checked in the File Inspector.

- [ ] **Step 3: Run the tests; confirm they fail to compile**

Run:

```bash
xcodebuild -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' test 2>&1 | tail -40
```

Expected: build failure with "cannot find 'WhisperPromptBuilder' in scope" and "cannot find type 'VocabularyTokenizing' in scope".

- [ ] **Step 4: Create the production file**

Create `voxline/Transcription/WhisperPromptBuilder.swift`:

```swift
import Foundation

/// Minimal tokenizer interface that `WhisperPromptBuilder` depends on. Two
/// reasons for the local protocol rather than `WhisperTokenizer` directly:
/// (1) tests can substitute a deterministic fake without pulling WhisperKit
/// into the test target's link graph, and (2) the builder doesn't need the
/// 6-method `WhisperTokenizer` surface — only `encode(text:)` and the
/// special-token threshold.
protocol VocabularyTokenizing {
    /// First token ID at or above which a token is special (e.g. language
    /// tokens, timestamps, end-of-text). Tokens >= this threshold are filtered
    /// out of the prompt by WhisperKit itself; we do the same so our token
    /// count matches what's actually consumed.
    var specialTokenBegin: Int { get }
    func encode(text: String) -> [Int]
}

/// Builds the `promptTokens` array for `DecodingOptions` from a flat list of
/// canonical vocabulary terms. Pure functions; no state.
enum WhisperPromptBuilder {

    /// WhisperKit's internal cap on `promptTokens` is `maxTokenContext/2 - 1`
    /// = 223 for the standard 448-context Whisper models. We cap at 200 so
    /// the UI counter agrees with what's actually used and we have headroom
    /// for variants with slightly different limits.
    static let promptTokenBudget = 200

    /// Compact, naturally-occurring joiner: comma-space between terms,
    /// trailing period. Empty input returns an empty string.
    static func promptString(from terms: [String]) -> String {
        guard !terms.isEmpty else { return "" }
        return terms.joined(separator: ", ") + "."
    }

    /// Tokenize the joined-term string, drop any special-token IDs, and
    /// truncate to the budget by removing terms from the tail.
    ///
    /// Strategy: rather than tokenize the full string and chop bytes off the
    /// end (which would split a term mid-token and confuse the decoder),
    /// we extend the kept-prefix one term at a time until the next term
    /// would overflow.
    static func promptTokens(
        from terms: [String],
        tokenizer: VocabularyTokenizing,
        budget: Int = promptTokenBudget
    ) -> [Int] {
        guard !terms.isEmpty else { return [] }
        var kept: [String] = []
        for term in terms {
            let candidate = kept + [term]
            let tokens = filteredTokens(for: promptString(from: candidate), tokenizer: tokenizer)
            if tokens.count > budget { break }
            kept.append(term)
        }
        return filteredTokens(for: promptString(from: kept), tokenizer: tokenizer)
    }

    /// Live count for the Settings UI. Same path as `promptTokens` so the
    /// number matches what transcribe will actually use. No budget cap is
    /// applied here — the caller decides what to do with an over-budget
    /// number.
    static func tokenCount(of terms: [String], tokenizer: VocabularyTokenizing) -> Int {
        filteredTokens(for: promptString(from: terms), tokenizer: tokenizer).count
    }

    private static func filteredTokens(for text: String, tokenizer: VocabularyTokenizing) -> [Int] {
        guard !text.isEmpty else { return [] }
        return tokenizer.encode(text: text).filter { $0 < tokenizer.specialTokenBegin }
    }
}
```

- [ ] **Step 5: Add the new production file to the `voxline` Xcode target**

Same procedure as Step 2 but for `voxline/Transcription/WhisperPromptBuilder.swift` against the **voxline** target. Mirror the membership of `TranscriptionService.swift`.

- [ ] **Step 6: Run the tests; confirm they pass**

```bash
xcodebuild -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/WhisperPromptBuilderTests test 2>&1 | tail -30
```

Expected: `Test Suite 'WhisperPromptBuilderTests' passed` with 6 tests.

- [ ] **Step 7: Commit**

```bash
git add voxline/Transcription/WhisperPromptBuilder.swift voxlineTests/WhisperPromptBuilderTests.swift voxline.xcodeproj/project.pbxproj
git commit -m "$(cat <<'EOF'
feat(transcription): WhisperPromptBuilder for vocab biasing

Pure builder over a minimal VocabularyTokenizing protocol. Joins
terms with ", " + trailing period, filters special-token IDs, and
truncates by dropping whole terms from the tail so partial tokens
never reach the decoder. Default budget 200 (under WhisperKit's
internal 223 cap).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Extend `Transcribing` protocol and `TranscriptionService`

**Files:**
- Modify: `voxline/Pipeline/PipelineProtocols.swift`
- Modify: `voxline/Transcription/TranscriptionService.swift`

- [ ] **Step 1: Update the protocol**

In `voxline/Pipeline/PipelineProtocols.swift`, replace the `Transcribing` definition:

```swift
@MainActor
protocol Transcribing: AnyObject {
    /// Transcribe a Float32 PCM buffer at AudioFormat.whisperSampleRate.
    /// `vocabulary` is a list of canonical terms used to bias the Whisper
    /// decoder via `DecodingOptions.promptTokens`. Pass an empty array to
    /// disable biasing.
    func transcribe(samples: [Float], vocabulary: [String]) async throws -> String

    /// Live token count of `terms` against the active Whisper model's
    /// tokenizer. Used by the Settings UI to show budget headroom. Throws
    /// if the tokenizer cannot be obtained (model load failed).
    func tokenCount(for terms: [String]) async throws -> Int
}
```

- [ ] **Step 2: Update `TranscriptionService`**

In `voxline/Transcription/TranscriptionService.swift`, replace the existing `transcribe(samples:)` method and add the new helper. Find the existing block:

```swift
    /// Transcribe a Float32 PCM buffer at AudioFormat.whisperSampleRate.
    func transcribe(samples: [Float]) async throws -> String {
        let kit = try await loadIfNeeded()
        let results = try await kit.transcribe(audioArray: samples)
        return results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
```

Replace with:

```swift
    /// Transcribe a Float32 PCM buffer at AudioFormat.whisperSampleRate.
    /// When `vocabulary` is non-empty, builds promptTokens via
    /// `WhisperPromptBuilder` and passes them through DecodingOptions to
    /// bias the decoder toward those terms. Empty input → omit promptTokens
    /// entirely (WhisperKit treats `[]` differently from `nil`).
    func transcribe(samples: [Float], vocabulary: [String] = []) async throws -> String {
        let kit = try await loadIfNeeded()
        let tokens: [Int]
        if vocabulary.isEmpty {
            tokens = []
        } else if let tokenizer = kit.tokenizer {
            tokens = WhisperPromptBuilder.promptTokens(from: vocabulary, tokenizer: tokenizer)
        } else {
            // Tokenizer absent on a loaded kit is a WhisperKit-internal
            // edge case; we keep going without biasing rather than fail
            // the dictation.
            tokens = []
        }
        let options: DecodingOptions = tokens.isEmpty
            ? DecodingOptions()
            : DecodingOptions(promptTokens: tokens)
        let results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
        return results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Count tokens that `terms` would contribute when fed to Whisper. Loads
    /// the model if needed so the count matches reality. Used by the Settings
    /// vocabulary UI to render `N / 200 tokens` and to gate the Add button.
    func tokenCount(for terms: [String]) async throws -> Int {
        guard !terms.isEmpty else { return 0 }
        let kit = try await loadIfNeeded()
        guard let tokenizer = kit.tokenizer else { return 0 }
        return WhisperPromptBuilder.tokenCount(of: terms, tokenizer: tokenizer)
    }
```

The `WhisperTokenizer` returned by `kit.tokenizer` is `WhisperTokenizer?`. Because we need `VocabularyTokenizing`, but the public surface returned is the protocol type, add a tiny shim inside this file (don't touch `WhisperPromptBuilder.swift` again):

```swift
private extension WhisperTokenizer {
    /// Bridge: lifts the existential `WhisperTokenizer` to the local
    /// `VocabularyTokenizing` protocol so the builder can consume it. We
    /// can't add this in WhisperPromptBuilder.swift directly because
    /// retroactive conformance of an imported protocol is restricted under
    /// Swift 6; this file-private adapter sidesteps that.
    var asVocabularyTokenizing: VocabularyTokenizing {
        struct Adapter: VocabularyTokenizing {
            let underlying: WhisperTokenizer
            var specialTokenBegin: Int { underlying.specialTokens.specialTokenBegin }
            func encode(text: String) -> [Int] { underlying.encode(text: text) }
        }
        return Adapter(underlying: self)
    }
}
```

Then use `tokenizer.asVocabularyTokenizing` when calling into `WhisperPromptBuilder` from both methods. Concretely:

```swift
            tokens = WhisperPromptBuilder.promptTokens(from: vocabulary, tokenizer: tokenizer.asVocabularyTokenizing)
```

and

```swift
        return WhisperPromptBuilder.tokenCount(of: terms, tokenizer: tokenizer.asVocabularyTokenizing)
```

- [ ] **Step 3: Build to confirm protocol + impl compile**

```bash
xcodebuild -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' build 2>&1 | tail -25
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Commit**

```bash
git add voxline/Pipeline/PipelineProtocols.swift voxline/Transcription/TranscriptionService.swift
git commit -m "$(cat <<'EOF'
feat(transcription): thread vocabulary into transcribe + tokenCount

Transcribing protocol grows a `vocabulary:` parameter; service builds
promptTokens via WhisperPromptBuilder when non-empty. Adds
tokenCount(for:) helper for the Settings UI.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Wire vocabulary into `CapturePipeline`

**Files:**
- Modify: `voxline/Pipeline/CapturePipeline.swift`
- Modify: `voxline/voxlineApp.swift` or wherever `CapturePipeline` is constructed (search first)

- [ ] **Step 1: Find where `CapturePipeline` is constructed in production**

```bash
grep -rn 'CapturePipeline(' /Users/toddfredricks/GitHub/voxline/voxline --include='*.swift'
```

Note the production call site (likely `voxlineApp.swift` or an `AppState`/`AppContainer` file). Record the file path for Step 4.

- [ ] **Step 2: Add a `vocabularyStore` property and init parameter to `CapturePipeline`**

In `voxline/Pipeline/CapturePipeline.swift`, add the property and init parameter. Find:

```swift
    private let historyStore: DictationHistoryStore
    private let contextCapture: ContextCapturing
    private var contextTask: Task<CapturedContext, Never>?
```

Add a property:

```swift
    private let vocabularyStore: CustomVocabularyStore
```

In the initializer's parameter list, add `vocabularyStore: CustomVocabularyStore` after `contextCapture`:

```swift
    init(
        state: AppState,
        capture: AudioCapturing,
        transcriber: Transcribing,
        llm: LLMServing,
        modes: ModeResolving,
        frontmost: FrontmostAppProviding,
        fieldInspector: FocusedFieldInspecting,
        injector: ClipboardInjecting,
        historyStore: DictationHistoryStore,
        contextCapture: ContextCapturing,
        vocabularyStore: CustomVocabularyStore = CustomVocabularyStore()
    ) {
```

In the init body, assign the new property:

```swift
        self.vocabularyStore = vocabularyStore
```

- [ ] **Step 3: Read vocab and pass to transcribe**

Still in `CapturePipeline.swift`, find the existing transcribe call:

```swift
        // 1. Transcribe locally.
        let transcript: String
        let transcribeInterval = signposter.beginInterval("transcribe", id: sessionID)
        let transcribeStart = Date()
        do {
            transcript = try await transcriber.transcribe(samples: samples)
            signposter.endInterval("transcribe", transcribeInterval)
```

Replace `transcript = try await transcriber.transcribe(samples: samples)` with:

```swift
            // Read vocab synchronously off the store. Cheap (single
            // UserDefaults read). The ContextCaptureService also reads
            // this list onto the captured context, so the same terms flow
            // to the LLM cleanup pass as well — the two reads are
            // independent of each other and may briefly differ if the
            // user edited the list between them; not worth coordinating.
            let vocab = vocabularyStore.load()
            transcript = try await transcriber.transcribe(samples: samples, vocabulary: vocab)
```

- [ ] **Step 4: Update the production construction site**

In whatever file the grep in Step 1 surfaced, add `vocabularyStore: CustomVocabularyStore()` to the `CapturePipeline(...)` call. (If the call uses positional arguments without the parameter, the default value covers it — but prefer to be explicit so the wiring is obvious in the call site.)

- [ ] **Step 5: Build**

```bash
xcodebuild -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' build 2>&1 | tail -15
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 6: Commit**

```bash
git add voxline/Pipeline/CapturePipeline.swift voxline/voxlineApp.swift
# Add any other touched construction site instead of voxlineApp.swift if the grep in Step 1 pointed elsewhere.
git commit -m "$(cat <<'EOF'
feat(pipeline): load vocab and pass to transcriber

CapturePipeline gains an injected CustomVocabularyStore (defaulted for
production wiring) and reads the list in finalizeRecording, passing
it to transcribe(samples:vocabulary:).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Update `CapturePipelineTests` for the new transcriber signature

**Files:**
- Modify: `voxlineTests/CapturePipelineTests.swift`

- [ ] **Step 1: Update `FakeTranscriber` to capture the vocab argument**

In `voxlineTests/CapturePipelineTests.swift`, replace the existing `FakeTranscriber` class:

```swift
    final class FakeTranscriber: Transcribing {
        var nextResult: Result<String, Error> = .success("hello world")
        var transcribeCallCount = 0
        var lastVocabulary: [String] = []
        var tokenCountResult: Result<Int, Error> = .success(0)
        func transcribe(samples: [Float], vocabulary: [String]) async throws -> String {
            transcribeCallCount += 1
            lastVocabulary = vocabulary
            return try nextResult.get()
        }
        func tokenCount(for terms: [String]) async throws -> Int {
            try tokenCountResult.get()
        }
    }
```

- [ ] **Step 2: Update `makePipeline` to thread a `CustomVocabularyStore` through**

Find the `makePipeline` helper. Add a parameter and pass it into the constructor:

```swift
    private func makePipeline(
        frontmostBundleID: String? = "com.tinyspeck.slackmacgap",
        focusedField: FocusedField? = nil,
        modes: [Mode] = [
            Mode(bundleID: "com.tinyspeck.slackmacgap", displayName: "Slack", prompt: "slack-prompt", model: nil, temperature: nil),
            Mode(bundleID: "*", displayName: "Default", prompt: "default-prompt", model: nil, temperature: nil)
        ],
        vocabulary: [String] = []
    ) -> (pipe: CapturePipeline, state: AppState, capture: FakeCapture, transcriber: FakeTranscriber, llm: FakeLLM, frontmost: FakeFrontmost, inspector: FakeFieldInspector, injector: FakeInjector, history: DictationHistoryStore) {
        // ... existing body ...
        let suiteName = "voxline-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let history = DictationHistoryStore(defaults: defaults)
        let vocabStore = CustomVocabularyStore(defaults: defaults)
        vocabStore.save(vocabulary)
        let pipe = CapturePipeline(
            state: state, capture: capture, transcriber: transcriber,
            llm: llm, modes: router, frontmost: front,
            fieldInspector: inspector, injector: injector,
            historyStore: history, contextCapture: FakeContextCapture(),
            vocabularyStore: vocabStore
        )
        return (pipe, state, capture, transcriber, llm, front, inspector, injector, history)
    }
```

Apply the same `vocabularyStore: vocabStore` addition to `makePipelineWithContext` (also constructs a `CapturePipeline`).

- [ ] **Step 3: Add a new test that asserts vocab flows through**

Append at the end of `@Suite @MainActor struct CapturePipelineTests`:

```swift
    @Test func finalize_passes_loaded_vocab_to_transcriber() async {
        let (pipe, state, _, transcriber, _, _, _, _, _) = makePipeline(vocabulary: ["Argmax", "LangGraph"])
        pipe.startRecording()
        state.lastPeakLevel = 0.5
        await pipe.finalizeRecording()
        #expect(transcriber.lastVocabulary == ["Argmax", "LangGraph"])
    }

    @Test func finalize_with_empty_store_passes_empty_vocab() async {
        let (pipe, state, _, transcriber, _, _, _, _, _) = makePipeline()
        pipe.startRecording()
        state.lastPeakLevel = 0.5
        await pipe.finalizeRecording()
        #expect(transcriber.lastVocabulary.isEmpty)
    }
```

- [ ] **Step 4: Run the test suite**

```bash
xcodebuild -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/CapturePipelineTests test 2>&1 | tail -30
```

Expected: all existing `CapturePipelineTests` pass plus the two new ones.

- [ ] **Step 5: Commit**

```bash
git add voxlineTests/CapturePipelineTests.swift
git commit -m "$(cat <<'EOF'
test(pipeline): cover vocab passthrough in capture pipeline

FakeTranscriber records lastVocabulary; new tests assert the store's
contents reach the transcriber and that an empty store yields an
empty vocab argument.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Update other consumers of `Transcribing`

**Files:**
- Modify: `voxlineTests/TranscriptionServiceTests.swift` (if it has tests calling `transcribe(samples:)` directly)
- Modify: Any other in-codebase `Transcribing` conformers (search first)

- [ ] **Step 1: Find all current callers**

```bash
grep -rn '\.transcribe(samples:' /Users/toddfredricks/GitHub/voxline --include='*.swift'
grep -rn ': Transcribing' /Users/toddfredricks/GitHub/voxline --include='*.swift'
```

- [ ] **Step 2: Update each non-pipeline call site**

For every call to `transcribe(samples:)`, append `, vocabulary: []` (or a specific list if the test is about vocab). For every `Transcribing` conformer (real or fake) other than `TranscriptionService` and `FakeTranscriber` (already done), add the new method signatures.

If `TranscriptionServiceTests.swift` exists and contains tests that call `transcribe(samples:)` with a real `WhisperKit`-backed service, leave their behavior alone but update the signature: pass `vocabulary: []`.

- [ ] **Step 3: Build + run full test suite**

```bash
xcodebuild -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' test 2>&1 | tail -40
```

Expected: all tests pass. If any test fails for unrelated reasons, **stop and report** — don't proceed with implementation on a red bar.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "test: thread empty vocab through pre-existing transcribe callers

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: Update LLM preamble for canonical-vocab normalization

**Files:**
- Modify: `voxline/LLM/LLMService.swift` (the `transcriptionPreamble` constant only)

- [ ] **Step 1: Replace the existing context-rules paragraph**

In `voxline/LLM/LLMService.swift`, find the existing paragraph in `transcriptionPreamble`:

```swift
    If a Context section follows the transcript, treat it as background \
    signal: ground proper nouns and spellings against it, match the \
    register and punctuation density of any surrounding text shown, and \
    preserve any listed vocabulary verbatim. Never quote, echo, or \
    summarize Context fields — the transcript is the only source of text \
    to return.

    Style guidance for this dictation:
```

Replace with:

```swift
    If a Context section follows the transcript, treat it as background \
    signal: ground proper nouns and spellings against it, and match the \
    register and punctuation density of any surrounding text shown. \
    Never quote, echo, or summarize Context fields — the transcript is \
    the only source of text to return.

    If a `Custom vocabulary` line appears in the Context block, treat \
    each comma-separated entry as a canonical spelling. When a \
    transcript word is phonetically close to one of those entries but \
    differs in spelling, case, word-segmentation, or letter-spacing, \
    replace the transcript form with the canonical form. Never invent \
    terms that are not in the list. If a vocabulary term appears \
    consecutively two or more times with no other content between, \
    collapse it to a single occurrence.

    Style guidance for this dictation:
```

- [ ] **Step 2: Add a snapshot-style test on the preamble**

Append to `voxlineTests/LLMServiceTests.swift` (or create `voxlineTests/LLMPreambleTests.swift` and add it to the test target if there's no obvious slot):

```swift
    @Test func transcriptionPreamble_contains_canonical_vocab_rule() {
        let preamble = LLMService.transcriptionPreamble
        #expect(preamble.contains("Custom vocabulary"))
        #expect(preamble.contains("canonical spelling"))
        #expect(preamble.contains("Never invent terms that are not in the list"))
        #expect(preamble.contains("collapse it to a single occurrence"))
    }

    @Test func transcriptionPreamble_keeps_existing_cleaning_rules() {
        let preamble = LLMService.transcriptionPreamble
        // Sanity: the un-touched rules survived the edit.
        #expect(preamble.contains("Strip fillers"))
        #expect(preamble.contains("Resolve self-corrections"))
        #expect(preamble.contains("Preserve proper nouns"))
    }
```

If creating a new test file, add it to the `voxlineTests` Xcode target (same procedure as Task 1 Step 2).

- [ ] **Step 3: Run LLM tests**

```bash
xcodebuild -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/LLMServiceTests test 2>&1 | tail -25
```

Expected: existing tests pass + the two new preamble tests pass.

- [ ] **Step 4: Commit**

```bash
git add voxline/LLM/LLMService.swift voxlineTests/LLMServiceTests.swift
git commit -m "$(cat <<'EOF'
feat(llm): canonical-spelling normalization in preamble

Strengthens the vocab clause from "preserve verbatim" to "replace
phonetically-close transcript words with the canonical form" and
adds a duplicate-collapse rule to mitigate the known promptTokens
repetition failure mode.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: `CustomVocabularyListViewModel` (TDD)

**Files:**
- Create: `voxline/Settings/Components/CustomVocabularyListViewModel.swift`
- Create: `voxlineTests/CustomVocabularyListViewModelTests.swift`
- Modify: `voxline.xcodeproj/project.pbxproj`

- [ ] **Step 1: Create the test file**

Create `voxlineTests/CustomVocabularyListViewModelTests.swift`:

```swift
import Testing
import Foundation
@testable import voxline

@Suite @MainActor struct CustomVocabularyListViewModelTests {

    private func suite() -> UserDefaults {
        let name = "voxline-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    private func makeVM(
        initial: [String] = [],
        tokenCounter: @escaping @Sendable ([String]) async throws -> Int = { _ in 0 },
        budget: Int = 200
    ) -> (vm: CustomVocabularyListViewModel, store: CustomVocabularyStore) {
        let store = CustomVocabularyStore(defaults: suite())
        store.save(initial)
        let vm = CustomVocabularyListViewModel(
            store: store,
            budget: budget,
            tokenCounter: tokenCounter
        )
        return (vm, store)
    }

    @Test func loadFromStore_populates_terms_in_order() {
        let (vm, _) = makeVM(initial: ["Argmax", "LangGraph", "MSL"])
        #expect(vm.terms == ["Argmax", "LangGraph", "MSL"])
    }

    @Test func addTerm_trims_and_persists() {
        let (vm, store) = makeVM()
        vm.draft = "  Argmax  "
        vm.addTerm()
        #expect(vm.terms == ["Argmax"])
        #expect(store.load() == ["Argmax"])
        #expect(vm.draft == "")
    }

    @Test func addTerm_ignores_exact_duplicate() {
        let (vm, _) = makeVM(initial: ["Argmax"])
        vm.draft = "Argmax"
        vm.addTerm()
        #expect(vm.terms == ["Argmax"])
    }

    @Test func addTerm_ignores_empty_after_trim() {
        let (vm, _) = makeVM()
        vm.draft = "   "
        vm.addTerm()
        #expect(vm.terms.isEmpty)
    }

    @Test func removeTerm_persists() {
        let (vm, store) = makeVM(initial: ["Argmax", "LangGraph"])
        vm.remove("Argmax")
        #expect(vm.terms == ["LangGraph"])
        #expect(store.load() == ["LangGraph"])
    }

    @Test func canAdd_is_false_when_typed_term_would_exceed_budget() async {
        // Counter reports current+draft >= budget for any nonempty term.
        let counter: @Sendable ([String]) async throws -> Int = { terms in
            terms.contains("HUGE") ? 999 : 50
        }
        let (vm, _) = makeVM(initial: [], tokenCounter: counter, budget: 200)
        await vm.refreshCount()
        vm.draft = "HUGE"
        // The view-model probes the counter with [current..., draft].
        await vm.refreshCanAdd()
        #expect(vm.canAdd == false)
    }

    @Test func canAdd_is_true_when_typed_term_fits() async {
        let counter: @Sendable ([String]) async throws -> Int = { _ in 10 }
        let (vm, _) = makeVM(initial: [], tokenCounter: counter, budget: 200)
        await vm.refreshCount()
        vm.draft = "Argmax"
        await vm.refreshCanAdd()
        #expect(vm.canAdd == true)
    }

    @Test func refreshCount_falls_back_to_heuristic_when_counter_throws() async {
        struct E: Error {}
        let counter: @Sendable ([String]) async throws -> Int = { _ in throw E() }
        let (vm, _) = makeVM(initial: ["one two three"], tokenCounter: counter)
        await vm.refreshCount()
        // Heuristic: ~1.3 tokens per word → ceil(3 * 1.3) = 4.
        #expect(vm.tokenCount == 4)
        #expect(vm.tokenCountIsApproximate == true)
    }
}
```

- [ ] **Step 2: Add the test file to `voxlineTests` target** (same procedure as Task 1 Step 2).

- [ ] **Step 3: Run tests; confirm compile failure**

```bash
xcodebuild -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/CustomVocabularyListViewModelTests test 2>&1 | tail -20
```

Expected: "cannot find 'CustomVocabularyListViewModel' in scope".

- [ ] **Step 4: Create the production view-model**

Create `voxline/Settings/Components/CustomVocabularyListViewModel.swift`:

```swift
import Foundation
import Observation

/// View-model for `CustomVocabularyListView`. Owns the in-memory `terms`
/// array, persists every mutation through `CustomVocabularyStore`, and keeps
/// an asynchronous token count up to date against an injected
/// `tokenCounter` (typically `TranscriptionService.tokenCount(for:)`).
///
/// The counter is async because counting requires the Whisper tokenizer,
/// which lives behind the model load. The view-model never blocks edits on
/// the counter — it shows a stale count, kicks off a refresh, and updates
/// when it returns.
@Observable
@MainActor
final class CustomVocabularyListViewModel {

    /// Live, displayed list. Stays sorted in user-edit order (store order).
    private(set) var terms: [String] = []

    /// Bound to the Add field.
    var draft: String = ""

    /// Last computed token count of `terms`. May briefly lag mutations
    /// while a refresh is in flight; refreshed on every add/remove.
    private(set) var tokenCount: Int = 0

    /// True when `tokenCount` was produced by the word-heuristic fallback
    /// (counter threw, typically because the Whisper model hasn't loaded
    /// yet). The view shows an "approximate" note when this is true.
    private(set) var tokenCountIsApproximate: Bool = false

    /// True when adding `draft` (trimmed) would not exceed the budget.
    /// Disabled when `draft` is empty-after-trim or a duplicate.
    private(set) var canAdd: Bool = false

    let budget: Int

    private let store: CustomVocabularyStore
    private let tokenCounter: @Sendable ([String]) async throws -> Int

    init(
        store: CustomVocabularyStore,
        budget: Int = WhisperPromptBuilder.promptTokenBudget,
        tokenCounter: @escaping @Sendable ([String]) async throws -> Int
    ) {
        self.store = store
        self.budget = budget
        self.tokenCounter = tokenCounter
        self.terms = store.load()
    }

    func addTerm() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !terms.contains(trimmed) else { draft = ""; return }
        terms.append(trimmed)
        store.save(terms)
        draft = ""
        Task { await self.refreshCount() }
    }

    func remove(_ term: String) {
        terms.removeAll { $0 == term }
        store.save(terms)
        Task { await self.refreshCount() }
    }

    /// Recompute `tokenCount` against the current `terms`. Called on init
    /// (via the view's `.task`), after every mutation, and when the
    /// underlying Whisper model changes.
    func refreshCount() async {
        do {
            tokenCount = try await tokenCounter(terms)
            tokenCountIsApproximate = false
        } catch {
            tokenCount = Self.heuristicCount(of: terms)
            tokenCountIsApproximate = true
        }
        await refreshCanAdd()
    }

    /// Recompute `canAdd` against the current `draft` plus the cached
    /// `tokenCount`. Called from the view as `draft` changes (via
    /// `.onChange`) and after `refreshCount()`.
    func refreshCanAdd() async {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !terms.contains(trimmed) else {
            canAdd = false
            return
        }
        let candidate = terms + [trimmed]
        do {
            let next = try await tokenCounter(candidate)
            canAdd = next <= budget
        } catch {
            // Counter unavailable: fall back to a generous heuristic, but
            // never refuse adds purely because we can't measure.
            canAdd = Self.heuristicCount(of: candidate) <= budget
        }
    }

    /// Word-count heuristic: ~1.3 tokens per whitespace-delimited word.
    /// Used only when the real tokenizer is unreachable.
    private static func heuristicCount(of terms: [String]) -> Int {
        let words = terms.reduce(0) { acc, term in
            acc + term.split(whereSeparator: { $0.isWhitespace }).count
        }
        return Int(ceil(Double(words) * 1.3))
    }
}
```

- [ ] **Step 5: Add the production file to the `voxline` target** (same procedure as Task 1 Step 5).

- [ ] **Step 6: Run the tests**

```bash
xcodebuild -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/CustomVocabularyListViewModelTests test 2>&1 | tail -30
```

Expected: `Test Suite 'CustomVocabularyListViewModelTests' passed` with 8 tests.

- [ ] **Step 7: Commit**

```bash
git add voxline/Settings/Components/CustomVocabularyListViewModel.swift voxlineTests/CustomVocabularyListViewModelTests.swift voxline.xcodeproj/project.pbxproj
git commit -m "$(cat <<'EOF'
feat(settings): CustomVocabularyListViewModel

Owns add/remove against the store, async token-count refresh, and
canAdd budget enforcement. Falls back to a 1.3-tokens-per-word
heuristic when the Whisper tokenizer is unreachable; never blocks
edits on the counter.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: `CustomVocabularyListView`

**Files:**
- Create: `voxline/Settings/Components/CustomVocabularyListView.swift`
- Modify: `voxline.xcodeproj/project.pbxproj`

(No new tests — SwiftUI body rendering isn't unit-tested in this project's style; the view-model carries the logic.)

- [ ] **Step 1: Create the view**

Create `voxline/Settings/Components/CustomVocabularyListView.swift`:

```swift
import SwiftUI

/// SwiftUI section for managing the global custom-vocabulary list. Rows show
/// each term with a delete button; an inline Add field appends a new term
/// after trim + dedupe; a footer shows `N terms · X / 200 tokens`.
///
/// All state lives in `CustomVocabularyListViewModel`. The view passes the
/// current `whisperModel` selection so it can re-trigger token-count
/// refresh when the user switches Whisper models.
struct CustomVocabularyListView: View {

    @Bindable var viewModel: CustomVocabularyListViewModel
    let whisperModel: WhisperModel

    var body: some View {
        Section("Custom vocabulary") {
            if viewModel.terms.isEmpty {
                Text("Add names, products, and acronyms that get mis-transcribed.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else {
                ForEach(viewModel.terms, id: \.self) { term in
                    HStack {
                        Text(term)
                        Spacer()
                        Button {
                            viewModel.remove(term)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove \(term)")
                    }
                }
            }

            HStack {
                TextField("Add term", text: $viewModel.draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        if viewModel.canAdd { viewModel.addTerm() }
                    }
                    .onChange(of: viewModel.draft) {
                        Task { await viewModel.refreshCanAdd() }
                    }
                Button("Add") { viewModel.addTerm() }
                    .disabled(!viewModel.canAdd)
            }

            HStack(spacing: 6) {
                Text("\(viewModel.terms.count) term\(viewModel.terms.count == 1 ? "" : "s") · \(viewModel.tokenCount) / \(viewModel.budget) tokens")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                if viewModel.tokenCountIsApproximate {
                    Text("(approximate — Whisper model not yet loaded)")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
            }
        }
        .task {
            await viewModel.refreshCount()
        }
        .onChange(of: whisperModel) {
            // Different tokenizer; recompute against the new model.
            Task { await viewModel.refreshCount() }
        }
    }
}
```

- [ ] **Step 2: Add the view file to the `voxline` target.**

- [ ] **Step 3: Build**

```bash
xcodebuild -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' build 2>&1 | tail -20
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Commit**

```bash
git add voxline/Settings/Components/CustomVocabularyListView.swift voxline.xcodeproj/project.pbxproj
git commit -m "$(cat <<'EOF'
feat(settings): CustomVocabularyListView UI

Replaces the stub TextEditor with a row-based list, inline Add field,
and a token-budget footer. Refreshes the count on appear and when the
Whisper model changes.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: Wire the new list view into `SettingsView`

**Files:**
- Modify: `voxline/Settings/SettingsView.swift`
- Modify: `voxline/Settings/GeneralSettingsViewModel.swift`

- [ ] **Step 1: Construct the view-model on `SettingsView`**

In `voxline/Settings/SettingsView.swift`, near where `generalVM` is held, add a stored property for the vocab view-model. The exact location depends on the existing class/struct shape — look for where `generalVM: GeneralSettingsViewModel` is declared and add alongside it. Example:

```swift
    @State private var vocabularyVM: CustomVocabularyListViewModel
```

Construct it in the view's initializer (or `@State` initializer), pulling the tokenizer from the same `TranscriptionService` that the rest of the app uses. The cleanest path: thread `TranscriptionService` into `SettingsView`'s init the same way other services are. If `SettingsView` already takes a service container or `AppState`, fish the transcriber from there.

Concretely, where `SettingsView` is constructed in the app (search with `grep -rn 'SettingsView(' voxline --include='*.swift'`), add the transcription service as a dependency, then inside `SettingsView`'s init:

```swift
    init(general: GeneralSettingsViewModel, apiKeys: APIKeysSettingsViewModel, transcriber: TranscriptionService) {
        self.generalVM = general
        self.apiKeysVM = apiKeys
        let store = CustomVocabularyStore()
        let weakTranscriber = transcriber
        _vocabularyVM = State(initialValue: CustomVocabularyListViewModel(
            store: store,
            tokenCounter: { @Sendable terms in
                try await weakTranscriber.tokenCount(for: terms)
            }
        ))
    }
```

(Adjust the existing init parameters to match whatever's already there — this snippet shows the additions, not a wholesale replacement.)

- [ ] **Step 2: Replace the existing vocab section**

Find the existing block in `SettingsView.swift`:

```swift
                    Section("Custom vocabulary") {
                        TextEditor(text: $generalVM.customVocabularyText)
                            .font(.body)
                            .frame(minHeight: 60)
                        Text("Comma- or newline-separated. Helps the cleanup model spell names, acronyms, and product terms correctly.")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    }
                    .id(SettingsAnchor.customVocabulary)
```

Replace with:

```swift
                    CustomVocabularyListView(
                        viewModel: vocabularyVM,
                        whisperModel: generalVM.whisperModel
                    )
                    .id(SettingsAnchor.customVocabulary)
```

- [ ] **Step 3: Drop `customVocabularyText` from `GeneralSettingsViewModel`**

In `voxline/Settings/GeneralSettingsViewModel.swift`, delete this property block (lines roughly 20–26):

```swift
    var customVocabularyText: String {
        didSet {
            guard loaded, oldValue != customVocabularyText else { return }
            let terms = CustomVocabularyStore.parse(customVocabularyText)
            vocabulary.save(terms)
        }
    }
```

In the initializer, delete the line:

```swift
        self.customVocabularyText = vocabulary.load().joined(separator: ", ")
```

In `resetToDefaults()`, delete the line:

```swift
        customVocabularyText = ""
```

Keep `vocabulary.save([])` in `resetToDefaults()` and the `vocabulary: CustomVocabularyStore` member — they're still load-bearing.

- [ ] **Step 4: Update `GeneralSettingsViewModelTests`**

In `voxlineTests/GeneralSettingsViewModelTests.swift`, delete the two tests `customVocabularyText_load_returns_persisted_terms_joined` and `customVocabularyText_setting_persists_through_store`. Keep any `resetToDefaults` test that asserts the vocab store is cleared.

- [ ] **Step 5: Update production wiring of `SettingsView`**

In whatever file constructs `SettingsView(...)` (likely `voxlineApp.swift`), pass the existing `TranscriptionService` in. The service should already exist in the production wiring (it's used by `CapturePipeline`). Reuse the same instance.

- [ ] **Step 6: Build + full test suite**

```bash
xcodebuild -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' test 2>&1 | tail -40
```

Expected: `BUILD SUCCEEDED` and `** TEST SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
git add voxline/Settings/SettingsView.swift voxline/Settings/GeneralSettingsViewModel.swift voxlineTests/GeneralSettingsViewModelTests.swift voxline/voxlineApp.swift
git commit -m "$(cat <<'EOF'
feat(settings): replace vocab TextEditor with list view

SettingsView now constructs CustomVocabularyListViewModel against the
shared TranscriptionService and renders CustomVocabularyListView.
GeneralSettingsViewModel.customVocabularyText (and its two unit tests)
deleted; vocabulary store reference retained for resetToDefaults.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: Remove the stale stub comment in `CustomVocabularyStore`

**Files:**
- Modify: `voxline/Storage/CustomVocabularyStore.swift`

- [ ] **Step 1: Replace the doc comment**

Find the existing comment block at the top of the file:

```swift
/// Global custom-vocabulary list. Plain `[String]` persisted to UserDefaults.
/// Intentionally minimal: this is a stub for feature #9, which will replace it
/// with per-mode dictionaries. `load()` is called once per dictation; keep it
/// fast (single defaults read).
///
/// `@unchecked Sendable` mirrors `AppSettings`: `UserDefaults` isn't formally
/// `Sendable` but is documented thread-safe, and this struct holds no other
/// shared mutable state.
```

Replace with:

```swift
/// Global custom-vocabulary list. Plain `[String]` persisted to UserDefaults.
/// `load()` is called once per dictation (by `CapturePipeline`) and once
/// per `ContextCaptureService.capture()`; keep it fast (single defaults
/// read). The list feeds both `WhisperPromptBuilder.promptTokens` and the
/// LLM cleanup context block.
///
/// `@unchecked Sendable` mirrors `AppSettings`: `UserDefaults` isn't formally
/// `Sendable` but is documented thread-safe, and this struct holds no other
/// shared mutable state.
```

- [ ] **Step 2: Build**

```bash
xcodebuild -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' build 2>&1 | tail -10
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
git add voxline/Storage/CustomVocabularyStore.swift
git commit -m "docs(storage): refresh CustomVocabularyStore doc comment

Drops the stale 'stub for feature #9' line. This file is now the
backing store for feature 8 (custom vocabulary).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 11: Update the feature roadmap

**Files:**
- Modify: `docs/features.md`

- [ ] **Step 1: Flip the checkbox**

In `docs/features.md`, change:

```markdown
8. [ ] **Custom vocabulary** — Lets users add names, company terms, acronyms, technical terms, product names, and personal shorthand so transcription gets them right.
```

to:

```markdown
8. [x] **Custom vocabulary** — Lets users add names, company terms, acronyms, technical terms, product names, and personal shorthand so transcription gets them right.
```

- [ ] **Step 2: Commit**

```bash
git add docs/features.md
git commit -m "docs(features): mark custom vocabulary as shipped

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 12: Manual smoke test

**Files:**
- None — this is end-to-end verification on the running app.

- [ ] **Step 1: Run the app from Xcode**

Open `voxline.xcodeproj`, select the `voxline` scheme + My Mac destination, ⌘R.

- [ ] **Step 2: Smoke checklist**

Walk through each:

1. **Empty list regression** — Open Settings → Custom vocabulary section is empty. Dictate "the quick brown fox" into TextEdit. Final text appears as expected. Behavior unchanged from before this feature.
2. **Bias works for spelling/casing** — Add `Argmax` and `LangGraph`. Dictate "the are max team shipped lang graph today" into TextEdit. Final text says "the Argmax team shipped LangGraph today" (or similar canonical-spelling correction).
3. **Bias works for novel term** — Add a clearly novel term (e.g. `Zorblax`). Dictate "Zorblax shipped". Final text contains `Zorblax` spelled correctly.
4. **Budget cap** — Repeatedly add long terms (e.g. `supercalifragilisticexpialidocious` plus other long words). Watch the footer counter climb. When it reaches the budget, the Add button disables and the typed term cannot be added.
5. **Whisper model swap** — Open Settings → Recognition → switch the Whisper model. Return to Custom vocabulary section; the token counter re-runs (briefly shows the prior value, then updates). Re-test bias case (2) — still works against the new model.
6. **Delete-all** — Remove every term. Dictation continues to work; the LLM context block no longer carries a `Custom vocabulary:` line (verify by enabling the debug LLM dump: launch with env `VOXLINE_TRACE_LLM=1` and inspect stdout in Xcode's console).
7. **Reset to Defaults** — Click "Reset to Defaults" in General Settings. Confirm the vocab list clears.

- [ ] **Step 3: Record any deviation as a follow-up issue**

If anything misbehaves, **do not** silently patch — capture the symptom, the steps, and (if possible) the relevant `VOXLINE_TRACE_LLM=1` dump, and surface it for review.

- [ ] **Step 4: (Optional) tag a clean state**

If everything passes, no commit needed — this task is verification only. The roadmap commit in Task 11 already records "shipped".

---

## Done criteria

All eleven implementation tasks (1–11) committed; Task 12's seven smoke cases verified manually; `xcodebuild ... test` is green; the only on-disk vocabulary code that survives is:

- `CustomVocabularyStore` (unchanged shape, refreshed comment)
- `WhisperPromptBuilder` + tests
- `TranscriptionService.transcribe(samples:vocabulary:)` + `.tokenCount(for:)` + tests
- `CapturePipeline` reading the store
- `LLMService.transcriptionPreamble` revised paragraph + snapshot tests
- `CustomVocabularyListViewModel` + tests
- `CustomVocabularyListView`
- `SettingsView` wired to the new view

The old TextEditor section and `GeneralSettingsViewModel.customVocabularyText` no longer exist anywhere in the tree.
