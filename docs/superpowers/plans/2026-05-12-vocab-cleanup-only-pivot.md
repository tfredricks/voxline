# Vocab cleanup-only pivot — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the broken WhisperKit `promptTokens` vocab-biasing path from voxline and rely solely on the LLM-cleanup-prompt vocab biasing that is already wired up end-to-end.

**Architecture:** This is primarily a deletion. The cleanup-layer path (`ContextCaptureService` → `CapturedContext.customVocabulary` → `ContextBlockFormatter` → `LLMService.transcriptionPreamble`) stays untouched and continues to deliver vocabulary biasing. Code paths removed: `WhisperPromptBuilder`, `TranscriptionService.tokenCount`, the `vocabulary:` parameter on `Transcribing.transcribe`, the four-threshold-disable branch in `DecodingOptions`, and the token-count UI in the settings vocab list. Tests for the dead code go with it; a new live end-to-end test exercises the surviving path.

**Tech Stack:** Swift 6 (strict concurrency), Swift Testing (`@Suite`, `@Test`), WhisperKit (`argmax-oss-swift`), SwiftUI, AVFoundation (`AVSpeechSynthesizer` for synthesized audio in tests), real Anthropic/OpenAI API call in the new integration test.

**Reference spec:** `docs/superpowers/specs/2026-05-12-vocab-cleanup-only-pivot-design.md`

---

## Task 1: Simplify `Transcribing` protocol

**Files:**
- Modify: `voxline/Pipeline/PipelineProtocols.swift:14-25`

The protocol exposes two methods that disappear after the pivot: a `vocabulary:` parameter on `transcribe` and the standalone `tokenCount(for:)`. Both will be removed before touching their implementation (next task) so the build error surfaces every caller cleanly.

- [ ] **Step 1: Edit protocol**

Replace lines 14-25 with:

```swift
@MainActor
protocol Transcribing: AnyObject {
    /// Transcribe a Float32 PCM buffer at AudioFormat.whisperSampleRate.
    /// Vocabulary biasing happens later in the pipeline via the LLM cleanup
    /// prompt — see `LLMService.transcriptionPreamble`. WhisperKit's
    /// `promptTokens` decoder-biasing path was removed because it produced
    /// empty output for short non-prose term lists; see
    /// `docs/superpowers/specs/2026-05-12-vocab-cleanup-only-pivot-design.md`.
    func transcribe(samples: [Float]) async throws -> String
}
```

- [ ] **Step 2: Verify build now fails on callers**

Run:
```bash
xcodebuild -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' build 2>&1 | grep -E "error:|tokenCount|vocabulary" | head -20
```
Expected: errors at `voxline/Transcription/TranscriptionService.swift` (the concrete conformance), `voxline/Pipeline/CapturePipeline.swift:148` (vocabulary call site), `voxline/voxlineApp.swift:63` (`tokenCount` call site), and `voxline/Settings/Components/CustomVocabularyListViewModel.swift` (uses the counter closure). These are expected and will be fixed in the next tasks.

- [ ] **Step 3: Do not commit yet**

Keep the working tree dirty; the next task lands the matching `TranscriptionService` change.

---

## Task 2: Strip vocab + threshold-disable + tokenCount from `TranscriptionService`

**Files:**
- Modify: `voxline/Transcription/TranscriptionService.swift`

- [ ] **Step 1: Replace `transcribe` body**

Replace the entire `transcribe(samples:vocabulary:)` method (currently lines 117-182) with this trimmed-down version. The doc comment, threshold-disable branch, vocab-prompt branch, and verbose `print` block all go away.

```swift
    /// Transcribe a Float32 PCM buffer at AudioFormat.whisperSampleRate.
    /// Returns the concatenated text across all decoded segments, trimmed.
    /// Vocabulary biasing is handled downstream by `LLMService` against the
    /// `CapturedContext.customVocabulary` line in the prompt.
    func transcribe(samples: [Float]) async throws -> String {
        let kit = try await loadIfNeeded()
        let results = try await kit.transcribe(audioArray: samples, decodeOptions: DecodingOptions())
        return results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
```

- [ ] **Step 2: Delete `tokenCount(for:)`**

Remove the entire method block (currently lines 184-194):

```swift
    func tokenCount(for terms: [String]) async throws -> Int {
        guard !terms.isEmpty else { return 0 }
        let kit = try await loadIfNeeded()
        guard let tokenizer = kit.tokenizer else {
            throw TranscriptionPrepError.tokenizerUnavailable
        }
        return WhisperPromptBuilder.tokenCount(of: terms, tokenizer: tokenizer.asVocabularyTokenizing)
    }
```

- [ ] **Step 3: Delete the `WhisperTokenizerVocabularyAdapter` adapter**

Remove the file-private adapter and its extension at the bottom of the file (currently lines 282-300):

```swift
private struct WhisperTokenizerVocabularyAdapter: VocabularyTokenizing {
    let underlying: WhisperTokenizer
    var specialTokenBegin: Int { underlying.specialTokens.specialTokenBegin }
    func encode(text: String) -> [Int] { underlying.encode(text: text) }
}

private extension WhisperTokenizer {
    var asVocabularyTokenizing: VocabularyTokenizing {
        WhisperTokenizerVocabularyAdapter(underlying: self)
    }
}
```

Note: `TranscriptionPrepError.tokenizerUnavailable` is still defined and may still be referenced by `voxlineApp.swift:61` until Task 6. Do not delete it in this task — let Task 6 remove the last reference first, and Task 6's check will confirm no other callers exist before pruning the enum case.

- [ ] **Step 4: Compile (will still fail at other call sites)**

Run:
```bash
xcodebuild -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' build 2>&1 | grep -E "error:" | head -10
```
Expected: errors remain at `CapturePipeline.swift`, `voxlineApp.swift`, `CustomVocabularyListViewModel.swift`. The TranscriptionService.swift file should no longer report errors.

- [ ] **Step 5: Do not commit yet**

Tasks 1-7 land together as one logical change. Keep editing.

---

## Task 3: Update `CapturePipeline` to call new `transcribe(samples:)`

**Files:**
- Modify: `voxline/Pipeline/CapturePipeline.swift`

The pipeline stores a `vocabularyStore` purely to feed the doomed Whisper-prompt path. The store is **also** read independently by `ContextCaptureService`, so removing it from `CapturePipeline` doesn't break the cleanup-layer biasing.

- [ ] **Step 1: Remove the stored property**

Delete line 19:
```swift
    private let vocabularyStore: CustomVocabularyStore
```

- [ ] **Step 2: Remove the init parameter and assignment**

In the initializer (lines 22-34), drop the `vocabularyStore: CustomVocabularyStore` parameter. Drop the `self.vocabularyStore = vocabularyStore` line (line 45).

The init's parameter list should end with:
```swift
        contextCapture: ContextCapturing
    ) {
```

- [ ] **Step 3: Replace the transcribe call site**

Replace lines 140-148 (the vocab read + transcribe call) with:

```swift
        do {
            transcript = try await transcriber.transcribe(samples: samples)
            signposter.endInterval("transcribe", transcribeInterval)
```

Make sure the closing `} catch {` block at line 150 is preserved — the change is only the lines from `do {` through the `transcribe(...)` call.

- [ ] **Step 4: Build**

Run:
```bash
xcodebuild -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' build 2>&1 | grep -E "error:" | head -10
```
Expected: errors remain at `voxlineApp.swift` (still passes `vocabularyStore:` to `CapturePipeline.init` and still references `tokenCount`) and `CustomVocabularyListViewModel.swift`.

---

## Task 4: Delete `WhisperPromptBuilder.swift` and its tests

**Files:**
- Delete: `voxline/Transcription/WhisperPromptBuilder.swift`
- Delete: `voxlineTests/WhisperPromptBuilderTests.swift`

- [ ] **Step 1: Remove the files**

Run:
```bash
rm voxline/Transcription/WhisperPromptBuilder.swift voxlineTests/WhisperPromptBuilderTests.swift
```

- [ ] **Step 2: Verify no remaining references in app code**

Run:
```bash
grep -rn "WhisperPromptBuilder\|VocabularyTokenizing" voxline voxlineTests 2>/dev/null
```
Expected: empty output (modulo the `CustomVocabularyListViewModel` reference to `WhisperPromptBuilder.promptTokenBudget` at line 43 — that is fixed in Task 5).

- [ ] **Step 3: Build (one remaining caller of the deleted symbol)**

Run:
```bash
xcodebuild -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' build 2>&1 | grep -E "error:" | head -10
```
Expected: error at `CustomVocabularyListViewModel.swift:43` for `WhisperPromptBuilder.promptTokenBudget`. Fixed in Task 5.

---

## Task 5: Simplify `CustomVocabularyListViewModel`

**Files:**
- Modify: `voxline/Settings/Components/CustomVocabularyListViewModel.swift`

The view-model carries five fields and three methods that only existed to feed the token-budget UI: `tokenCount`, `tokenCountIsApproximate`, `canAdd`, `budget`, `tokenCounter`, `heuristicCount`, `refreshCount`, `refreshCanAdd`. `canAdd` stays because the view's Add button binds to it, but it becomes a simple "non-empty after trim, not a duplicate" check.

- [ ] **Step 1: Rewrite the file**

Replace the entire file contents with:

```swift
import Foundation
import Observation

/// View-model for `CustomVocabularyListView`. Owns the in-memory `terms`
/// array and persists every mutation through `CustomVocabularyStore`.
/// Vocab biasing now flows through the LLM cleanup prompt; the Whisper
/// `promptTokens` path (and the token-budget UI that fed it) was removed
/// per `docs/superpowers/specs/2026-05-12-vocab-cleanup-only-pivot-design.md`.
@Observable
@MainActor
final class CustomVocabularyListViewModel {

    /// Live, displayed list. Stays in user-edit order (store order).
    private(set) var terms: [String] = []

    /// Bound to the Add field.
    var draft: String = ""

    /// True when adding `draft` (trimmed) is meaningful: non-empty and not
    /// already in the list. Drives the Add button's disabled state.
    var canAdd: Bool {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !terms.contains(trimmed)
    }

    private let store: CustomVocabularyStore

    init(store: CustomVocabularyStore) {
        self.store = store
        self.terms = store.load()
    }

    func addTerm() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !terms.contains(trimmed) else { draft = ""; return }
        terms.append(trimmed)
        store.save(terms)
        draft = ""
    }

    func remove(_ term: String) {
        terms.removeAll { $0 == term }
        store.save(terms)
    }

    /// Re-read `terms` from the store. Used when something outside the
    /// view-model mutates the store (e.g. `GeneralSettingsViewModel.resetToDefaults`
    /// clears it). Without this the displayed list keeps showing entries the
    /// store no longer holds until the Settings window is reopened.
    func reload() {
        terms = store.load()
    }
}
```

- [ ] **Step 2: Build**

Run:
```bash
xcodebuild -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' build 2>&1 | grep -E "error:" | head -10
```
Expected: errors remain at `CustomVocabularyListView.swift` (footer references the removed fields) and `SettingsView.swift` + `voxlineApp.swift` (init signature changed).

---

## Task 6: Simplify the vocab list view, the settings init, and the app wiring

**Files:**
- Modify: `voxline/Settings/Components/CustomVocabularyListView.swift`
- Modify: `voxline/Settings/SettingsView.swift`
- Modify: `voxline/voxlineApp.swift`
- Modify: `voxline/Transcription/TranscriptionService.swift` (prune now-unused `tokenizerUnavailable` enum case)

- [ ] **Step 1: Simplify the list view**

Replace the entire body of `voxline/Settings/Components/CustomVocabularyListView.swift` with:

```swift
import SwiftUI

/// SwiftUI section for managing the global custom-vocabulary list. Rows show
/// each term with a delete button; an inline Add field appends after trim +
/// dedupe; a footer shows `N terms`. Vocab biasing now flows through the LLM
/// cleanup prompt — see
/// `docs/superpowers/specs/2026-05-12-vocab-cleanup-only-pivot-design.md`.
struct CustomVocabularyListView: View {

    @Bindable var viewModel: CustomVocabularyListViewModel

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
                Button("Add") { viewModel.addTerm() }
                    .disabled(!viewModel.canAdd)
            }

            Text("\(viewModel.terms.count) term\(viewModel.terms.count == 1 ? "" : "s")")
                .foregroundStyle(.secondary)
                .font(.callout)
        }
    }
}
```

Note the removed surface: `whisperModel` property (no longer needed; nothing in this view depends on the Whisper model), `.task` for `refreshCount`, `.onChange(of: whisperModel)`, the approximate-count badge.

- [ ] **Step 2: Simplify `SettingsView.init`**

In `voxline/Settings/SettingsView.swift`, remove the `tokenCounter` parameter (line 17) and update the initializer body. The relevant section (lines 14-26) becomes:

```swift
    init(
        generalVM: GeneralSettingsViewModel,
        apiKeysVM: APIKeysSettingsViewModel
    ) {
        _generalVM = State(wrappedValue: generalVM)
        _apiKeysVM = State(wrappedValue: apiKeysVM)
        _status = State(wrappedValue: SettingsStatusViewModel(general: generalVM, keys: apiKeysVM))
        _vocabularyVM = State(wrappedValue: CustomVocabularyListViewModel(
            store: CustomVocabularyStore()
        ))
    }
```

Also update the `CustomVocabularyListView` call site (lines 97-101) to drop the `whisperModel:` parameter:

```swift
                    CustomVocabularyListView(viewModel: vocabularyVM)
                        .id(SettingsAnchor.customVocabulary)
```

- [ ] **Step 3: Update the `Settings { … }` scene in `voxlineApp.swift`**

In `voxline/voxlineApp.swift`, replace the `SettingsView(...)` block (lines 55-67) with:

```swift
        Settings {
            SettingsView(
                generalVM: GeneralSettingsViewModel(applier: delegate.coordinator),
                apiKeysVM: APIKeysSettingsViewModel()
            )
            .environment(delegate.appState)
        }
```

- [ ] **Step 4: Drop the `vocabularyStore:` argument to `CapturePipeline.init`**

In `voxline/voxlineApp.swift`, the `CapturePipeline(...)` construction (lines 235-247) loses the trailing `vocabularyStore: CustomVocabularyStore()` argument. The call becomes:

```swift
        let pipeline = CapturePipeline(
            state: state,
            capture: capture,
            transcriber: transcriber,
            llm: llm,
            modes: router,
            frontmost: frontmost,
            fieldInspector: fieldInspector,
            injector: injector,
            historyStore: historyStore,
            contextCapture: contextCapture
        )
```

- [ ] **Step 5: Prune the now-unused `tokenizerUnavailable` case**

Confirm no remaining references:
```bash
grep -rn "tokenizerUnavailable" voxline voxlineTests 2>/dev/null
```
Expected: only the case declaration and switch arm inside `voxline/Transcription/TranscriptionService.swift`.

In `voxline/Transcription/TranscriptionService.swift`, remove `case tokenizerUnavailable` from the `TranscriptionPrepError` enum and remove its corresponding `case .tokenizerUnavailable: return "..."` arm in `errorDescription`. Leave `insufficientDiskSpace` intact.

- [ ] **Step 6: Build**

Run:
```bash
xcodebuild -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`.

---

## Task 7: Remove the obsolete integration test

**Files:**
- Delete: `voxlineTests/Integration/VocabPipelineIntegrationTests.swift`

The current integration test asserts that Whisper returns non-empty when handed a vocab prompt. After the pivot, Whisper never sees the vocab — the assertion is meaningless. A new test goes in next.

- [ ] **Step 1: Delete the file**

Run:
```bash
rm voxlineTests/Integration/VocabPipelineIntegrationTests.swift
```

- [ ] **Step 2: Build for testing**

Run:
```bash
xcodebuild -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' build-for-testing 2>&1 | tail -5
```
Expected: `** TEST BUILD SUCCEEDED **`.

- [ ] **Step 3: Run the full unit test suite**

Run:
```bash
xcodebuild test-without-building -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' 2>&1 | tail -30
```
Expected: all suites pass. `WhisperPromptBuilderTests` no longer appears in the output (its file was deleted in Task 4). `VocabPipelineIntegrationTests` is also gone. Anything else that previously passed must still pass.

If a settings-related unit test references `tokenCount`, `budget`, or `tokenCountIsApproximate`, update it to drop those references (the value is now `viewModel.terms.count`). If no such tests exist, skip.

- [ ] **Step 4: Commit the deletion phase**

Run:
```bash
git add -u voxline voxlineTests
git status --short
```
Inspect the output — it should show modifications to the seven files touched in Tasks 1-6 and deletions of the three files (`WhisperPromptBuilder.swift`, `WhisperPromptBuilderTests.swift`, `VocabPipelineIntegrationTests.swift`).

Run:
```bash
git commit -m "$(cat <<'EOF'
refactor(vocab): remove broken WhisperKit promptTokens path

Vocabulary biasing now flows only through the LLM cleanup prompt, which
was already shipping (see LLMService.transcriptionPreamble). The
WhisperKit decoder-biasing channel produced empty output on short non-
prose term lists; WhisperKit's roadmap flags this as needing model-level
work.

- Drop vocabulary parameter from Transcribing.transcribe
- Drop tokenCount(for:) and the four-threshold disable branch
- Delete WhisperPromptBuilder + its unit tests + the WhisperTokenizer
  adapter + the tokenizerUnavailable error case
- Stop reading the vocab store in CapturePipeline (ContextCaptureService
  still reads it independently for the LLM cleanup path)
- Replace the token-budget settings UI with a plain term-count footer
- Delete the obsolete VocabPipelineIntegrationTests (asserted on the
  removed Whisper-prompt path)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Write the failing live end-to-end test

**Files:**
- Create: `voxlineTests/Integration/VocabCleanupIntegrationTests.swift`

The new test exercises the real pipeline: synthesized speech → real `TranscriptionService` → real `LLMService.cleanup` against the configured provider's live API → assert canonical terms appear in the cleaned output. It skips with a printed note when either the WhisperKit model is not cached or the configured provider's API key is missing.

- [ ] **Step 1: Create the file with the failing test**

Write the following to `voxlineTests/Integration/VocabCleanupIntegrationTests.swift`. The audio-synthesis + resampling helpers are intentionally near-duplicates of what was in the deleted `VocabPipelineIntegrationTests`; they're the right shape and not worth a shared helper yet (one consumer).

```swift
import Testing
import Foundation
@preconcurrency import AVFoundation
@testable import voxline

/// Tag for slow live integration tests. Re-declared here because the
/// original declaration lived in the deleted VocabPipelineIntegrationTests.
extension Tag {
    @Tag static var integration: Self
}

/// Live end-to-end integration test for the cleanup-layer vocab biasing
/// path. Synthesized speech runs through the real `TranscriptionService`
/// (WhisperKit) and then through the real `LLMService.cleanup` against the
/// configured provider's live API. Skips with a printed `[integration]`
/// note when the WhisperKit model is not cached locally OR the configured
/// provider's API key is missing from the Keychain.
///
/// See `docs/superpowers/specs/2026-05-12-vocab-cleanup-only-pivot-design.md`
/// for context on why the Whisper-prompt biasing channel was removed.
@Suite(.tags(.integration))
@MainActor
struct VocabCleanupIntegrationTests {

    private enum IntegrationError: Error {
        case targetFormatUnavailable
        case converterUnavailable
        case conversionFailed(NSError?)
        case emptyAudio
        case voiceUnavailable
    }

    /// Phrase designed to produce phonetic near-misses for two vocab terms.
    /// Whisper transcribes the proper-noun forms naturally; the cleanup pass
    /// is what should snap them to the canonical spellings.
    private static let phrase = "Please use lang graph and arg max in the daily report"

    @Test
    func cleanup_normalizes_phonetic_misses_to_canonical_terms() async throws {
        guard try await Self.modelIsAvailable() else { return }
        guard try Self.providerKeyIsAvailable() else { return }

        // 1. Real Whisper transcription on synthesized audio.
        let service = TranscriptionService(model: .default)
        try await service.prewarm()
        let samples = try await Self.synthesizeSpeechSamples(Self.phrase)
        let transcript = try await service.transcribe(samples: samples)
        #expect(transcript.count > 5, "expected non-empty raw transcript, got '\(transcript)'")

        // 2. Real LLM cleanup with vocab injected via CapturedContext.
        let settings = AppSettings()
        let llm = LLMService(settings: settings)
        var context = CapturedContext.empty
        context.customVocabulary = ["LangGraph", "Argmax"]
        let mode = Mode(
            bundleID: "*",
            displayName: "Test",
            prompt: "Concise. Preserve the speaker's word choice.",
            model: nil,
            temperature: 0.0,
            fieldKind: nil
        )
        let cleaned = try await llm.cleanup(transcript: transcript, mode: mode, context: context)

        // 3. The cleanup preamble (LLMService.transcriptionPreamble) instructs
        // the model to snap phonetic near-misses to the canonical spelling.
        // We assert case-sensitively on both canonical terms.
        #expect(cleaned.contains("LangGraph"),
                "expected cleaned output to contain canonical 'LangGraph'; got '\(cleaned)'")
        #expect(cleaned.contains("Argmax"),
                "expected cleaned output to contain canonical 'Argmax'; got '\(cleaned)'")
    }

    // MARK: - Skip gates

    private static func modelIsAvailable() async throws -> Bool {
        if TranscriptionService.isModelCached(.default) {
            return true
        }
        print("[integration] skipping VocabCleanupIntegrationTests — WhisperKit model not cached. Run the app once to download the default model and re-run.")
        return false
    }

    /// Returns true if the configured provider's Keychain key is present.
    /// Otherwise prints a skip note and returns false. Matches `LLMService`'s
    /// production resolution: read `AppSettings.llmProvider`, look up the
    /// matching account.
    private static func providerKeyIsAvailable() throws -> Bool {
        let settings = AppSettings()
        let provider = settings.llmProvider
        let account: String
        switch provider {
        case .anthropic: account = Keychain.Account.anthropic
        case .openai:    account = Keychain.Account.openai
        }
        let key = try Keychain().string(forKey: account)
        if let key, !key.isEmpty {
            return true
        }
        print("[integration] skipping VocabCleanupIntegrationTests — no API key in Keychain for provider \(provider). Add a key in Settings → API Keys.")
        return false
    }

    // MARK: - Audio synthesis

    /// Synthesizes `text` via AVSpeechSynthesizer and resamples the result to
    /// 16 kHz mono Float32 — Whisper's expected input format. See the
    /// callback contract: the write block delivers a sequence of PCM buffers
    /// terminated by an empty (frameLength == 0) buffer.
    /// https://developer.apple.com/documentation/avfaudio/avspeechsynthesizer/write(_:tobuffercallback:)
    @MainActor
    private static func synthesizeSpeechSamples(_ text: String) async throws -> [Float] {
        let synthesizer = AVSpeechSynthesizer()
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.voice = AVSpeechSynthesisVoice(identifier: "com.apple.voice.compact.en-US.Samantha")
            ?? AVSpeechSynthesisVoice.speechVoices().first { $0.language.hasPrefix("en") }
        guard utterance.voice != nil else {
            throw IntegrationError.voiceUnavailable
        }

        final class Box: @unchecked Sendable {
            var buffers: [AVAudioPCMBuffer] = []
            var resumed = false
        }
        let box = Box()

        let samples: [Float] = try await withCheckedThrowingContinuation { continuation in
            synthesizer.write(utterance) { buffer in
                guard !box.resumed else { return }
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 {
                    box.resumed = true
                    do {
                        let out = try resampleToWhisper(box.buffers)
                        continuation.resume(returning: out)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                    return
                }
                if let copy = pcm.deepCopy() {
                    box.buffers.append(copy)
                } else {
                    box.buffers.append(pcm)
                }
            }
        }

        guard !samples.isEmpty else { throw IntegrationError.emptyAudio }
        _ = synthesizer
        return samples
    }

    /// Concatenates the synthesizer's PCM buffers and converts to 16 kHz
    /// mono Float32. Mirrors the converter shape used in `AudioCaptureService`.
    private static func resampleToWhisper(_ buffers: [AVAudioPCMBuffer]) throws -> [Float] {
        guard let first = buffers.first else { return [] }
        let sourceFormat = first.format
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioFormat.whisperSampleRate,
            channels: AudioFormat.whisperChannelCount,
            interleaved: false
        ) else {
            throw IntegrationError.targetFormatUnavailable
        }
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw IntegrationError.converterUnavailable
        }

        let totalFrames = buffers.reduce(AVAudioFrameCount(0)) { $0 + $1.frameLength }
        guard totalFrames > 0,
              let combined = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: totalFrames) else {
            throw IntegrationError.emptyAudio
        }
        combined.frameLength = 0
        for buffer in buffers {
            appendBuffer(buffer, into: combined)
        }

        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(combined.frameLength) * ratio + 1024)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else {
            throw IntegrationError.converterUnavailable
        }

        var error: NSError?
        var consumed = false
        let status = converter.convert(to: outBuffer, error: &error) { _, statusOut in
            if consumed {
                statusOut.pointee = .endOfStream
                return nil
            }
            consumed = true
            statusOut.pointee = .haveData
            return combined
        }

        guard status != .error, error == nil, let channel = outBuffer.floatChannelData?[0] else {
            throw IntegrationError.conversionFailed(error)
        }
        let count = Int(outBuffer.frameLength)
        return Array(UnsafeBufferPointer(start: channel, count: count))
    }

    private static func appendBuffer(_ src: AVAudioPCMBuffer, into dst: AVAudioPCMBuffer) {
        let frames = src.frameLength
        guard frames > 0, dst.frameCapacity - dst.frameLength >= frames else { return }
        let channels = Int(src.format.channelCount)
        let bytesPerFrame = Int(src.format.streamDescription.pointee.mBytesPerFrame)
        let bytesPerChannelFrame = bytesPerFrame / max(1, channels)
        if let srcFloats = src.floatChannelData, let dstFloats = dst.floatChannelData {
            for ch in 0..<channels {
                let srcPtr = srcFloats[ch]
                let dstPtr = dstFloats[ch].advanced(by: Int(dst.frameLength))
                dstPtr.update(from: srcPtr, count: Int(frames))
            }
        } else if let srcInts = src.int16ChannelData, let dstInts = dst.int16ChannelData {
            for ch in 0..<channels {
                let srcPtr = srcInts[ch]
                let dstPtr = dstInts[ch].advanced(by: Int(dst.frameLength))
                dstPtr.update(from: srcPtr, count: Int(frames))
            }
        } else {
            let srcList = src.audioBufferList.pointee
            let dstList = dst.mutableAudioBufferList.pointee
            if let sData = srcList.mBuffers.mData, let dData = dstList.mBuffers.mData {
                let offset = Int(dst.frameLength) * bytesPerChannelFrame * channels
                memcpy(dData.advanced(by: offset), sData, Int(frames) * bytesPerFrame)
            }
        }
        dst.frameLength += frames
    }
}

private extension AVAudioPCMBuffer {
    /// Returns an independent buffer with the same format and frame
    /// contents. AVSpeechSynthesizer may reuse its internal buffer across
    /// callbacks, so we copy on every delivery.
    func deepCopy() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else {
            return nil
        }
        copy.frameLength = frameLength
        let channels = Int(format.channelCount)
        if let srcFloats = floatChannelData, let dstFloats = copy.floatChannelData {
            for ch in 0..<channels {
                dstFloats[ch].update(from: srcFloats[ch], count: Int(frameLength))
            }
            return copy
        }
        if let srcInts = int16ChannelData, let dstInts = copy.int16ChannelData {
            for ch in 0..<channels {
                dstInts[ch].update(from: srcInts[ch], count: Int(frameLength))
            }
            return copy
        }
        return nil
    }
}
```

- [ ] **Step 2: Build for testing**

Run:
```bash
xcodebuild -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' build-for-testing 2>&1 | tail -5
```
Expected: `** TEST BUILD SUCCEEDED **`.

- [ ] **Step 3: Run the new test**

Run:
```bash
xcodebuild test-without-building -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/VocabCleanupIntegrationTests 2>&1 | tail -30
```

Expected one of:
- **All-good path**: `cleanup_normalizes_phonetic_misses_to_canonical_terms()` passes. The cleaned text contains both `LangGraph` and `Argmax`.
- **Skip path (no model)**: prints `[integration] skipping VocabCleanupIntegrationTests — WhisperKit model not cached…` and passes.
- **Skip path (no key)**: prints `[integration] skipping VocabCleanupIntegrationTests — no API key in Keychain for provider…` and passes.

If the test **fails** (i.e., the cleaned text does not contain the canonical terms), inspect the logged `transcript` and `cleaned` strings in the test output. Likely fixes:
- Tighten the phrase used for synthesized audio (try a different sentence shape that produces a more obvious phonetic miss like `"lang graph"`).
- Confirm the configured provider/model honors low temperature deterministically.
- Confirm `LLMService.transcriptionPreamble` is unchanged from this branch's main.

Do not commit until the test passes (or you've confirmed it skips cleanly on a machine without a model/key).

- [ ] **Step 4: Commit the new test**

Run:
```bash
git add voxlineTests/Integration/VocabCleanupIntegrationTests.swift
git commit -m "$(cat <<'EOF'
test(vocab): live end-to-end test for cleanup-layer vocab biasing

Synthesized speech → real TranscriptionService → real LLMService.cleanup
against the configured provider's live API. Asserts the cleaned output
snaps phonetic near-misses ('lang graph', 'arg max') to the canonical
forms ('LangGraph', 'Argmax') declared via CapturedContext.customVocabulary.

Skips with a printed note when either the WhisperKit model is not
cached locally or the configured provider's Keychain key is absent.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: Final verification

- [ ] **Step 1: Full test suite**

Run:
```bash
xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' 2>&1 | tail -20
```
Expected: all suites green. The integration suite passes or skips with a printed note depending on local state.

- [ ] **Step 2: Manual smoke check via the app**

Launch the built app, open Settings → Custom vocabulary, add `LangGraph` and `Argmax`. Dictate a phrase like "please use lang graph in the report". Confirm the pasted output contains `LangGraph` (capital L, capital G). Repeat for `Argmax`.

This is the user-visible validation that the cleanup-layer biasing works end-to-end on real speech (not just synthesized).

- [ ] **Step 3: Done**

If both pieces pass, the pivot is complete. No further commits required.
