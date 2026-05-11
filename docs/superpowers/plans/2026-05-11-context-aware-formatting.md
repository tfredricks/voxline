# Context-Aware Formatting (#11) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Capture structured signals about where the user is dictating (app, window, focused-field surroundings, selection, visible labels, custom vocabulary) at push-to-talk press time and append them as a `Context:` block to the LLM cleanup user message. Mode prompts stay as the system message, unchanged.

**Architecture:** New `voxline/Context/` module owned by a `ContextCapturing` protocol that runs concurrently with audio capture during recording. The captured snapshot is handed to `LLMService.cleanup`, which uses a new `ContextBlockFormatter` to build the user message. A new `CustomVocabularyStore` provides a global vocab list (stub for feature #9). AX queries are wrapped in a 150ms total time budget with per-step deadlines and graceful partial results.

**Tech Stack:** Swift 6 (strict concurrency), AppKit, ApplicationServices (AX), `Testing` framework (`@Suite`, `@Test`, `#expect`), `OSLog` / signposts. Existing patterns followed: protocol-driven DI, fakes-in-tests, `AppLog` channels per concern.

**Spec:** `docs/superpowers/specs/2026-05-11-context-aware-formatting-design.md`

---

## File Map

**New files:**
- `voxline/Context/CapturedContext.swift` — value-type snapshot
- `voxline/Context/ContextBlockFormatter.swift` — `CapturedContext` → user-message string
- `voxline/Context/CaptureDeadline.swift` — time-budget helper
- `voxline/Context/ContextCaptureService.swift` — `ContextCapturing` protocol + sub-protocols + `DefaultContextCaptureService`
- `voxline/Context/AXContextProbe.swift` — `AXContextProbing` + real impl (window/value/selection)
- `voxline/Context/AXVisibleLabelsWalker.swift` — `AXVisibleLabelsWalking` + real impl (BFS)
- `voxline/Storage/CustomVocabularyStore.swift` — global `[String]` via UserDefaults
- `voxlineTests/CapturedContextTests.swift`
- `voxlineTests/ContextBlockFormatterTests.swift`
- `voxlineTests/CaptureDeadlineTests.swift`
- `voxlineTests/CustomVocabularyStoreTests.swift`
- `voxlineTests/ContextCaptureServiceTests.swift`

**Modified files:**
- `voxline/Pipeline/PipelineProtocols.swift` — `LLMServing.cleanup` gains a `context:` parameter; add `ContextCapturing` protocol re-export hint
- `voxline/Pipeline/CapturePipeline.swift` — inject `ContextCapturing`, fire capture concurrently with audio
- `voxline/LLM/LLMService.swift` — accept `CapturedContext`, build user message via `ContextBlockFormatter`
- `voxline/Diagnostics/AppLog.swift` — add `context` category
- `voxline/Settings/SettingsView.swift` — new "Custom vocabulary" section
- `voxline/Settings/GeneralSettingsViewModel.swift` — bind vocabulary text
- `voxline/Settings/GeneralSettingsApplier.swift` — add `customVocabulary` to snapshot (no-op apply; LLMService reads at call time)
- `voxline/voxlineApp.swift` — wire `DefaultContextCaptureService` into `buildServices`
- `voxlineTests/CapturePipelineTests.swift` — add `FakeContextCaptureService`, update `FakeLLM` signature
- `voxlineTests/LLMServiceTests.swift` — context-formatting assertions
- `docs/insertion-smoke-matrix.md` — add "Context captured" column

The Xcode project file (`voxline.xcodeproj/project.pbxproj`) must be updated whenever a new `.swift` file is added — there is no auto-discovery. Each new-file task includes the pbxproj edit step.

---

## Task 1: `CustomVocabularyStore` (isolated storage)

**Files:**
- Create: `voxline/Storage/CustomVocabularyStore.swift`
- Create: `voxlineTests/CustomVocabularyStoreTests.swift`
- Modify: `voxline.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write the failing test**

Create `voxlineTests/CustomVocabularyStoreTests.swift`:

```swift
import Testing
import Foundation
@testable import voxline

@Suite struct CustomVocabularyStoreTests {

    private func suite() -> UserDefaults {
        let name = "voxline-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func load_returns_empty_when_unset() {
        let store = CustomVocabularyStore(defaults: suite())
        #expect(store.load() == [])
    }

    @Test func save_then_load_roundtrips_terms() {
        let store = CustomVocabularyStore(defaults: suite())
        store.save(["Cursor", "LangGraph", "canonical_title"])
        #expect(store.load() == ["Cursor", "LangGraph", "canonical_title"])
    }

    @Test func save_trims_whitespace_and_drops_empty_entries() {
        let store = CustomVocabularyStore(defaults: suite())
        store.save(["  Cursor  ", "", "   ", "LangGraph\n"])
        #expect(store.load() == ["Cursor", "LangGraph"])
    }

    @Test func save_dedupes_case_sensitive() {
        let store = CustomVocabularyStore(defaults: suite())
        store.save(["Cursor", "Cursor", "cursor"])
        #expect(store.load() == ["Cursor", "cursor"])
    }

    @Test func parse_from_text_handles_comma_and_newline_separated() {
        let parsed = CustomVocabularyStore.parse("Cursor, LangGraph\ncanonical_title,,  ")
        #expect(parsed == ["Cursor", "LangGraph", "canonical_title"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme voxline -destination 'platform=macOS,arch=arm64' test -only-testing voxlineTests/CustomVocabularyStoreTests 2>&1 | tail -20`
Expected: build failure — `CustomVocabularyStore` not found.

- [ ] **Step 3: Implement `CustomVocabularyStore`**

Create `voxline/Storage/CustomVocabularyStore.swift`:

```swift
import Foundation

/// Global custom-vocabulary list. Plain `[String]` persisted to UserDefaults.
/// Intentionally minimal: this is a stub for feature #9, which will replace it
/// with per-mode dictionaries. `load()` is called once per dictation; keep it
/// fast (single defaults read).
struct CustomVocabularyStore: Sendable {

    static let key = "voxline.context.customVocabulary"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> [String] {
        defaults.stringArray(forKey: Self.key) ?? []
    }

    /// Persist `terms` after trimming whitespace, dropping empties, and
    /// deduping while preserving insertion order. Case-sensitive dedupe —
    /// users may want both `cursor` (CLI) and `Cursor` (editor).
    func save(_ terms: [String]) {
        let cleaned = Self.normalize(terms)
        defaults.set(cleaned, forKey: Self.key)
    }

    /// Convert the Settings text field's contents (comma- or newline-separated)
    /// into a list. Same normalization rules as `save`.
    static func parse(_ text: String) -> [String] {
        let separators = CharacterSet(charactersIn: ",\n")
        let pieces = text.components(separatedBy: separators)
        return normalize(pieces)
    }

    private static func normalize(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in terms {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { continue }
            if seen.insert(t).inserted { out.append(t) }
        }
        return out
    }
}
```

- [ ] **Step 4: Add the new files to the Xcode project**

Open `voxline.xcodeproj/project.pbxproj` and add references for `voxline/Storage/CustomVocabularyStore.swift` (target: `voxline`) and `voxlineTests/CustomVocabularyStoreTests.swift` (target: `voxlineTests`). Follow the existing patterns for `DictationHistoryStore.swift` and `DictationHistoryStoreTests.swift`: copy the four entries (PBXBuildFile, PBXFileReference, group children entry, sources phase entry) and substitute the new path and a fresh UUID for each.

- [ ] **Step 5: Run tests, verify pass**

Run: `xcodebuild -scheme voxline -destination 'platform=macOS,arch=arm64' test -only-testing voxlineTests/CustomVocabularyStoreTests 2>&1 | tail -20`
Expected: all 5 tests pass.

- [ ] **Step 6: Commit**

```bash
git add voxline/Storage/CustomVocabularyStore.swift voxlineTests/CustomVocabularyStoreTests.swift voxline.xcodeproj/project.pbxproj
git commit -m "feat(context): add CustomVocabularyStore for global vocab list (#11)"
```

---

## Task 2: `CapturedContext` value type

**Files:**
- Create: `voxline/Context/CapturedContext.swift`
- Create: `voxlineTests/CapturedContextTests.swift`
- Modify: `voxline.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write the failing test**

Create `voxlineTests/CapturedContextTests.swift`:

```swift
import Testing
import Foundation
@testable import voxline

@Suite struct CapturedContextTests {

    @Test func empty_has_all_optional_fields_nil_and_arrays_empty() {
        let c = CapturedContext.empty
        #expect(c.appName == nil)
        #expect(c.bundleID == nil)
        #expect(c.windowTitle == nil)
        #expect(c.fieldRole == nil)
        #expect(c.fieldSubrole == nil)
        #expect(c.isSecureField == false)
        #expect(c.textBeforeCursor == nil)
        #expect(c.textAfterCursor == nil)
        #expect(c.selectedText == nil)
        #expect(c.visibleLabels == [])
        #expect(c.customVocabulary == [])
        #expect(c.captureDurationMs == 0)
        #expect(c.captureNotes == [])
    }

    @Test func equality_ignores_nothing() {
        let a = CapturedContext.empty
        var b = CapturedContext.empty
        b.appName = "Slack"
        #expect(a != b)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme voxline -destination 'platform=macOS,arch=arm64' test -only-testing voxlineTests/CapturedContextTests 2>&1 | tail -20`
Expected: build failure — `CapturedContext` not found.

- [ ] **Step 3: Implement `CapturedContext`**

Create `voxline/Context/CapturedContext.swift`:

```swift
import Foundation

/// Snapshot of "where is the user dictating right now" signals captured at
/// push-to-talk press. Consumed by `ContextBlockFormatter` to build the LLM
/// user message. All optional/zero fields are omitted from the formatted
/// output — there is no "unknown" line in the prompt.
///
/// Caps on string/array lengths are enforced at the producer layer (probes
/// and the walker). The formatter does not re-trim.
struct CapturedContext: Equatable, Sendable {

    var appName: String?
    var bundleID: String?
    var windowTitle: String?
    var fieldRole: String?
    var fieldSubrole: String?
    /// True when the focused field is a secure text field (password input).
    /// When true, value-bearing lines (before/after cursor, selected text)
    /// are suppressed by the formatter.
    var isSecureField: Bool
    var textBeforeCursor: String?
    var textAfterCursor: String?
    var selectedText: String?
    var visibleLabels: [String]
    var customVocabulary: [String]
    /// Wall-clock duration of the capture, in milliseconds. Diagnostic only.
    var captureDurationMs: Int
    /// Short reason codes like "ax-timeout", "secure-field", "ax-not-trusted".
    /// Diagnostic only — never included in the prompt.
    var captureNotes: [String]

    static let empty = CapturedContext(
        appName: nil,
        bundleID: nil,
        windowTitle: nil,
        fieldRole: nil,
        fieldSubrole: nil,
        isSecureField: false,
        textBeforeCursor: nil,
        textAfterCursor: nil,
        selectedText: nil,
        visibleLabels: [],
        customVocabulary: [],
        captureDurationMs: 0,
        captureNotes: []
    )
}
```

- [ ] **Step 4: Add files to the Xcode project**

Add `voxline/Context/CapturedContext.swift` (target: `voxline`) and `voxlineTests/CapturedContextTests.swift` (target: `voxlineTests`) to `voxline.xcodeproj/project.pbxproj`. Create a new `Context` group under `voxline` mirroring the on-disk layout.

- [ ] **Step 5: Run tests, verify pass**

Run: `xcodebuild -scheme voxline -destination 'platform=macOS,arch=arm64' test -only-testing voxlineTests/CapturedContextTests 2>&1 | tail -20`
Expected: both tests pass.

- [ ] **Step 6: Commit**

```bash
git add voxline/Context/CapturedContext.swift voxlineTests/CapturedContextTests.swift voxline.xcodeproj/project.pbxproj
git commit -m "feat(context): add CapturedContext value type (#11)"
```

---

## Task 3: `ContextBlockFormatter`

**Files:**
- Create: `voxline/Context/ContextBlockFormatter.swift`
- Create: `voxlineTests/ContextBlockFormatterTests.swift`
- Modify: `voxline.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write the failing tests**

Create `voxlineTests/ContextBlockFormatterTests.swift`:

```swift
import Testing
import Foundation
@testable import voxline

@Suite struct ContextBlockFormatterTests {

    private let trailing = "Return only the final text to insert. Do not add quotes, prefixes, or commentary."

    @Test func empty_context_omits_context_block() {
        let out = ContextBlockFormatter.format(transcript: "hello world", context: .empty)
        #expect(out == """
        Raw transcript:
        "hello world"

        \(trailing)
        """)
    }

    @Test func full_context_emits_all_lines() {
        var c = CapturedContext.empty
        c.appName = "Slack"
        c.bundleID = "com.tinyspeck.slackmacgap"
        c.windowTitle = "#sales-pipeline — Acme workspace"
        c.fieldRole = "AXTextArea"
        c.textBeforeCursor = "Hey Kamil, following up on"
        c.textAfterCursor = ""
        c.selectedText = "the paragraph you highlighted"
        c.visibleLabels = ["Kamil Szczerba", "Q4 Renewal", "Acme"]
        c.customVocabulary = ["Cursor", "LangGraph", "canonical_title"]

        let out = ContextBlockFormatter.format(transcript: "send that update", context: c)

        #expect(out.contains("Raw transcript:\n\"send that update\""))
        #expect(out.contains("- App: Slack (com.tinyspeck.slackmacgap)"))
        #expect(out.contains("- Window: #sales-pipeline — Acme workspace"))
        #expect(out.contains("- Field: AXTextArea"))
        #expect(out.contains("- Selected text: \"the paragraph you highlighted\""))
        #expect(out.contains("- Text before cursor: \"Hey Kamil, following up on\""))
        #expect(out.contains("- Visible labels: [\"Kamil Szczerba\", \"Q4 Renewal\", \"Acme\"]"))
        #expect(out.contains("- Custom vocabulary: Cursor, LangGraph, canonical_title"))
        #expect(out.hasSuffix(trailing))
        // Empty text-after-cursor must be omitted, not emitted as "" line.
        #expect(!out.contains("- Text after cursor:"))
    }

    @Test func partial_context_omits_empty_lines() {
        var c = CapturedContext.empty
        c.appName = "Slack"
        c.bundleID = "com.tinyspeck.slackmacgap"
        // No window, no field, no text, no labels, no vocab.
        let out = ContextBlockFormatter.format(transcript: "hi", context: c)
        #expect(out.contains("Context:"))
        #expect(out.contains("- App: Slack (com.tinyspeck.slackmacgap)"))
        #expect(!out.contains("- Window:"))
        #expect(!out.contains("- Field:"))
        #expect(!out.contains("- Selected text:"))
        #expect(!out.contains("- Text before cursor:"))
        #expect(!out.contains("- Visible labels:"))
        #expect(!out.contains("- Custom vocabulary:"))
    }

    @Test func secure_field_suppresses_value_lines_but_keeps_app_and_window() {
        var c = CapturedContext.empty
        c.appName = "1Password"
        c.bundleID = "com.1password.1password"
        c.windowTitle = "Login"
        c.isSecureField = true
        c.textBeforeCursor = "hunter2"   // must NOT appear
        c.selectedText = "hunter2"       // must NOT appear
        c.visibleLabels = ["Email", "Password"]
        c.customVocabulary = ["Cursor"]
        let out = ContextBlockFormatter.format(transcript: "hi", context: c)
        #expect(out.contains("- App: 1Password (com.1password.1password)"))
        #expect(out.contains("- Window: Login"))
        #expect(out.contains("- Field: secure"))
        #expect(!out.contains("hunter2"))
        #expect(!out.contains("- Selected text:"))
        #expect(!out.contains("- Text before cursor:"))
        #expect(!out.contains("- Text after cursor:"))
        // Non-value lines still allowed.
        #expect(out.contains("- Visible labels: [\"Email\", \"Password\"]"))
        #expect(out.contains("- Custom vocabulary: Cursor"))
    }

    @Test func app_line_renders_without_bundle_id_when_missing() {
        var c = CapturedContext.empty
        c.appName = "Slack"
        let out = ContextBlockFormatter.format(transcript: "hi", context: c)
        #expect(out.contains("- App: Slack\n"))
        #expect(!out.contains("("))
    }

    @Test func transcript_is_escaped_for_embedded_quotes() {
        let out = ContextBlockFormatter.format(transcript: "she said \"hi\"", context: .empty)
        #expect(out.contains("\"she said \\\"hi\\\"\""))
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

Run: `xcodebuild -scheme voxline -destination 'platform=macOS,arch=arm64' test -only-testing voxlineTests/ContextBlockFormatterTests 2>&1 | tail -20`
Expected: build failure — `ContextBlockFormatter` not found.

- [ ] **Step 3: Implement `ContextBlockFormatter`**

Create `voxline/Context/ContextBlockFormatter.swift`:

```swift
import Foundation

/// Turns a `CapturedContext` into the user-message body the LLM receives.
///
/// Shape:
/// ```
/// Raw transcript:
/// "<transcript>"
///
/// Context:
/// - App: ...
/// - Window: ...
/// - Field: ...
/// - Selected text: "..."
/// - Text before cursor: "..."
/// - Text after cursor: "..."
/// - Visible labels: [...]
/// - Custom vocabulary: ...
///
/// Return only the final text to insert. Do not add quotes, prefixes, or commentary.
/// ```
///
/// Lines are omitted when their underlying values are nil/empty. The whole
/// `Context:` block is omitted when no fields would render. Secure-field
/// contexts suppress value-bearing lines but keep app/window/labels/vocab.
enum ContextBlockFormatter {

    static let trailingInstruction =
        "Return only the final text to insert. Do not add quotes, prefixes, or commentary."

    static func format(transcript: String, context: CapturedContext) -> String {
        var out = "Raw transcript:\n\"\(escape(transcript))\""
        let lines = contextLines(from: context)
        if !lines.isEmpty {
            out += "\n\nContext:\n"
            out += lines.joined(separator: "\n")
        }
        out += "\n\n\(trailingInstruction)"
        return out
    }

    private static func contextLines(from c: CapturedContext) -> [String] {
        var lines: [String] = []

        if let app = c.appName, !app.isEmpty {
            if let bid = c.bundleID, !bid.isEmpty {
                lines.append("- App: \(app) (\(bid))")
            } else {
                lines.append("- App: \(app)")
            }
        } else if let bid = c.bundleID, !bid.isEmpty {
            lines.append("- App: \(bid)")
        }

        if let w = c.windowTitle, !w.isEmpty {
            lines.append("- Window: \(w)")
        }

        if c.isSecureField {
            lines.append("- Field: secure")
        } else if let role = c.fieldRole, !role.isEmpty {
            lines.append("- Field: \(role)")
        }

        // Value-bearing lines: only when NOT a secure field.
        if !c.isSecureField {
            if let s = c.selectedText, !s.isEmpty {
                lines.append("- Selected text: \"\(escape(s))\"")
            }
            if let t = c.textBeforeCursor, !t.isEmpty {
                lines.append("- Text before cursor: \"\(escape(t))\"")
            }
            if let t = c.textAfterCursor, !t.isEmpty {
                lines.append("- Text after cursor: \"\(escape(t))\"")
            }
        }

        if !c.visibleLabels.isEmpty {
            let quoted = c.visibleLabels.map { "\"\(escape($0))\"" }.joined(separator: ", ")
            lines.append("- Visible labels: [\(quoted)]")
        }

        if !c.customVocabulary.isEmpty {
            lines.append("- Custom vocabulary: \(c.customVocabulary.joined(separator: ", "))")
        }

        return lines
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
```

- [ ] **Step 4: Add files to the Xcode project**

Add `voxline/Context/ContextBlockFormatter.swift` and `voxlineTests/ContextBlockFormatterTests.swift` to `voxline.xcodeproj/project.pbxproj`.

- [ ] **Step 5: Run tests, verify pass**

Run: `xcodebuild -scheme voxline -destination 'platform=macOS,arch=arm64' test -only-testing voxlineTests/ContextBlockFormatterTests 2>&1 | tail -20`
Expected: all 6 tests pass.

- [ ] **Step 6: Commit**

```bash
git add voxline/Context/ContextBlockFormatter.swift voxlineTests/ContextBlockFormatterTests.swift voxline.xcodeproj/project.pbxproj
git commit -m "feat(context): add ContextBlockFormatter (#11)"
```

---

## Task 4: `CaptureDeadline` helper

**Files:**
- Create: `voxline/Context/CaptureDeadline.swift`
- Create: `voxlineTests/CaptureDeadlineTests.swift`
- Modify: `voxline.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write the failing tests**

Create `voxlineTests/CaptureDeadlineTests.swift`:

```swift
import Testing
import Foundation
@testable import voxline

@Suite struct CaptureDeadlineTests {

    @Test func remaining_decreases_as_time_passes() async throws {
        let d = CaptureDeadline(totalMilliseconds: 200)
        let before = d.remainingMilliseconds()
        try await Task.sleep(nanoseconds: 50_000_000)   // 50ms
        let after = d.remainingMilliseconds()
        #expect(before > after)
        #expect(after <= 200)
    }

    @Test func isExpired_is_false_before_deadline_and_true_after() async throws {
        let d = CaptureDeadline(totalMilliseconds: 50)
        #expect(!d.isExpired)
        try await Task.sleep(nanoseconds: 80_000_000)   // 80ms
        #expect(d.isExpired)
    }

    @Test func remainingMilliseconds_returns_zero_when_expired() async throws {
        let d = CaptureDeadline(totalMilliseconds: 20)
        try await Task.sleep(nanoseconds: 40_000_000)
        #expect(d.remainingMilliseconds() == 0)
    }

    @Test func elapsedMilliseconds_reflects_wall_clock() async throws {
        let d = CaptureDeadline(totalMilliseconds: 1_000)
        try await Task.sleep(nanoseconds: 30_000_000)
        let elapsed = d.elapsedMilliseconds()
        #expect(elapsed >= 25 && elapsed <= 200)  // generous upper bound for CI
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

Run: `xcodebuild -scheme voxline -destination 'platform=macOS,arch=arm64' test -only-testing voxlineTests/CaptureDeadlineTests 2>&1 | tail -20`
Expected: build failure — `CaptureDeadline` not found.

- [ ] **Step 3: Implement `CaptureDeadline`**

Create `voxline/Context/CaptureDeadline.swift`:

```swift
import Foundation

/// Wall-clock deadline tracker used by `DefaultContextCaptureService` to give
/// each AX call a per-step budget without throwing on miss. Callers check
/// `isExpired` before starting work and consult `remainingMilliseconds()` if
/// they need to size an internal cap (e.g., max-nodes for the AX tree walk).
///
/// Monotonic via CFAbsoluteTime — not affected by wall-clock skew during a
/// push-to-talk session.
struct CaptureDeadline: Sendable {

    let totalMilliseconds: Int
    private let startedAt: CFAbsoluteTime

    init(totalMilliseconds: Int) {
        self.totalMilliseconds = totalMilliseconds
        self.startedAt = CFAbsoluteTimeGetCurrent()
    }

    func elapsedMilliseconds() -> Int {
        let dt = CFAbsoluteTimeGetCurrent() - startedAt
        return max(0, Int(dt * 1_000))
    }

    func remainingMilliseconds() -> Int {
        max(0, totalMilliseconds - elapsedMilliseconds())
    }

    var isExpired: Bool { remainingMilliseconds() == 0 }
}
```

- [ ] **Step 4: Add files to the Xcode project**

Add `voxline/Context/CaptureDeadline.swift` and `voxlineTests/CaptureDeadlineTests.swift` to `voxline.xcodeproj/project.pbxproj`.

- [ ] **Step 5: Run tests, verify pass**

Run: `xcodebuild -scheme voxline -destination 'platform=macOS,arch=arm64' test -only-testing voxlineTests/CaptureDeadlineTests 2>&1 | tail -20`
Expected: all 4 tests pass.

- [ ] **Step 6: Commit**

```bash
git add voxline/Context/CaptureDeadline.swift voxlineTests/CaptureDeadlineTests.swift voxline.xcodeproj/project.pbxproj
git commit -m "feat(context): add CaptureDeadline time-budget helper (#11)"
```

---

## Task 5: Define `ContextCapturing` protocol + AX sub-protocols

**Files:**
- Create: `voxline/Context/ContextCaptureService.swift` (protocol only; impl added in Task 8)
- Create: `voxline/Context/AXContextProbe.swift` (protocol only; impl added in Task 6)
- Create: `voxline/Context/AXVisibleLabelsWalker.swift` (protocol only; impl added in Task 7)
- Modify: `voxline.xcodeproj/project.pbxproj`

This task lays down the protocols so later tasks can stub them in fakes. No tests yet — pure type declarations.

- [ ] **Step 1: Create `ContextCaptureService.swift` with the top-level protocol**

```swift
import Foundation

/// Captures the user's current dictation context at push-to-talk press time.
/// Implementations run AX queries under a total time budget and must NEVER
/// throw — return a partial `CapturedContext` instead. Called from background
/// queues; must be `Sendable`.
protocol ContextCapturing: Sendable {
    /// Snapshot of the user's current focus + surroundings. Always returns;
    /// fields fall back to nil/empty when the underlying signal is unavailable.
    func capture() async -> CapturedContext
}
```

- [ ] **Step 2: Create `AXContextProbe.swift` with the per-probe protocol**

```swift
import Foundation

/// Carries the value-bearing AX outputs that depend on the focused element:
/// window title, the slice of the value before the cursor, the slice after,
/// and any current selection. The implementation may return any subset as
/// nil — the caller treats nil as "couldn't determine".
struct AXContextProbeResult: Equatable, Sendable {
    var windowTitle: String?
    var textBeforeCursor: String?
    var textAfterCursor: String?
    var selectedText: String?
}

/// Probes the system-wide focused element for value-bearing signals. Each
/// implementation should honor the passed deadline; if the deadline has
/// already expired, return all-nil immediately.
protocol AXContextProbing: Sendable {
    func probe(deadline: CaptureDeadline) -> AXContextProbeResult
}
```

- [ ] **Step 3: Create `AXVisibleLabelsWalker.swift` with the walker protocol**

```swift
import Foundation

/// Walks the focused window's AX subtree and returns visible label-like
/// strings (titles, descriptions, statics) — capped in count, depth, and
/// per-entry length by the implementation. Honors the deadline and returns
/// whatever was collected when the budget runs out.
protocol AXVisibleLabelsWalking: Sendable {
    func walk(deadline: CaptureDeadline) -> [String]
}
```

- [ ] **Step 4: Add files to the Xcode project**

Add the three new `.swift` files (target: `voxline`) to `voxline.xcodeproj/project.pbxproj`.

- [ ] **Step 5: Build to verify it compiles**

Run: `xcodebuild -scheme voxline -destination 'platform=macOS,arch=arm64' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Commit**

```bash
git add voxline/Context/ContextCaptureService.swift voxline/Context/AXContextProbe.swift voxline/Context/AXVisibleLabelsWalker.swift voxline.xcodeproj/project.pbxproj
git commit -m "feat(context): define ContextCapturing protocols (#11)"
```

---

## Task 6: `DefaultAXContextProbe` (real AX impl)

**Files:**
- Modify: `voxline/Context/AXContextProbe.swift` (add real impl below the protocol)
- Modify: `voxline.xcodeproj/project.pbxproj` (no new files, but ensure existing file is in sources phase — should already be from Task 5)

No unit test here — this exercises real AX APIs against a live process. Coverage comes from the smoke matrix (Task 14) and the orchestrator tests (Task 8) using a fake probe.

- [ ] **Step 1: Extend `AXContextProbe.swift` with `DefaultAXContextProbe`**

Append to `voxline/Context/AXContextProbe.swift`:

```swift
import ApplicationServices

/// Real AX-backed implementation. All AX calls are synchronous cross-process
/// IPC; each one is guarded with the deadline check so a slow target app
/// can't burn the whole budget on one attribute.
///
/// Caps:
/// - Window title: 200 chars (long titles get truncated with ellipsis).
/// - Selected text: 500 chars (longer selections are truncated; the LLM
///   doesn't need the whole thing to understand context).
/// - Text before cursor: 200 chars (slice ending at the cursor).
/// - Text after cursor: 100 chars (slice starting at the cursor).
struct DefaultAXContextProbe: AXContextProbing {

    static let windowTitleMax = 200
    static let selectedTextMax = 500
    static let beforeCursorMax = 200
    static let afterCursorMax = 100

    func probe(deadline: CaptureDeadline) -> AXContextProbeResult {
        var result = AXContextProbeResult()
        if deadline.isExpired { return result }
        guard AXIsProcessTrusted() else { return result }

        let system = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        let focusStatus = AXUIElementCopyAttributeValue(
            system, kAXFocusedUIElementAttribute as CFString, &focusedValue
        )
        guard focusStatus == .success,
              let focusedValue,
              CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            return result
        }
        let focused = focusedValue as! AXUIElement

        if deadline.isExpired { return result }
        result.windowTitle = readWindowTitle(focused: focused)

        if deadline.isExpired { return result }
        result.selectedText = clip(readString(focused, kAXSelectedTextAttribute), Self.selectedTextMax)

        if deadline.isExpired { return result }
        let (before, after) = readBeforeAfter(focused: focused)
        result.textBeforeCursor = before
        result.textAfterCursor = after

        return result
    }

    private func readWindowTitle(focused: AXUIElement) -> String? {
        var windowValue: CFTypeRef?
        let s = AXUIElementCopyAttributeValue(focused, kAXWindowAttribute as CFString, &windowValue)
        guard s == .success,
              let windowValue,
              CFGetTypeID(windowValue) == AXUIElementGetTypeID() else { return nil }
        let win = windowValue as! AXUIElement
        return clip(readString(win, kAXTitleAttribute), Self.windowTitleMax)
    }

    private func readBeforeAfter(focused: AXUIElement) -> (String?, String?) {
        // The selected-text range gives us the caret/anchor location; the
        // value attribute gives us the field's full content. Combine to
        // derive the slices around the cursor.
        var rangeValue: CFTypeRef?
        let rangeStatus = AXUIElementCopyAttributeValue(
            focused, kAXSelectedTextRangeAttribute as CFString, &rangeValue
        )
        guard rangeStatus == .success,
              let rangeValue,
              CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return (nil, nil) }

        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &range) else { return (nil, nil) }

        guard let full = readString(focused, kAXValueAttribute) else { return (nil, nil) }
        let nsFull = full as NSString
        let location = max(0, min(range.location, nsFull.length))

        let beforeStart = max(0, location - Self.beforeCursorMax)
        let beforeRange = NSRange(location: beforeStart, length: location - beforeStart)
        let beforeSlice = beforeRange.length > 0 ? nsFull.substring(with: beforeRange) : ""

        let afterStart = location
        let afterAvail = max(0, nsFull.length - afterStart)
        let afterLen = min(Self.afterCursorMax, afterAvail)
        let afterRange = NSRange(location: afterStart, length: afterLen)
        let afterSlice = afterRange.length > 0 ? nsFull.substring(with: afterRange) : ""

        return (beforeSlice.isEmpty ? nil : beforeSlice,
                afterSlice.isEmpty ? nil : afterSlice)
    }

    private func readString(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        let s = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard s == .success else { return nil }
        return value as? String
    }

    private func clip(_ s: String?, _ maxLen: Int) -> String? {
        guard let s, !s.isEmpty else { return nil }
        if s.count <= maxLen { return s }
        return String(s.prefix(maxLen - 1)) + "…"
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild -scheme voxline -destination 'platform=macOS,arch=arm64' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add voxline/Context/AXContextProbe.swift
git commit -m "feat(context): add DefaultAXContextProbe (window/value/selection) (#11)"
```

---

## Task 7: `DefaultAXVisibleLabelsWalker` (real AX impl)

**Files:**
- Modify: `voxline/Context/AXVisibleLabelsWalker.swift` (add real impl below the protocol)

No unit test — same rationale as Task 6.

- [ ] **Step 1: Extend `AXVisibleLabelsWalker.swift` with `DefaultAXVisibleLabelsWalker`**

Append to `voxline/Context/AXVisibleLabelsWalker.swift`:

```swift
import ApplicationServices

/// BFS over the focused window's AX subtree, collecting human-readable
/// label-like strings. Caps:
/// - Max collected labels: 20
/// - Max depth from the root window: 6
/// - Per-label char cap: 60
/// - Visits no more than 400 elements regardless of depth (guards against
///   pathological Electron trees).
///
/// Honors the deadline at every node — if `isExpired` flips true mid-walk,
/// returns what's been collected so far.
struct DefaultAXVisibleLabelsWalker: AXVisibleLabelsWalking {

    static let maxLabels = 20
    static let maxDepth = 6
    static let maxLabelChars = 60
    static let maxNodesVisited = 400

    private let attributes: [String] = [
        kAXTitleAttribute as String,
        kAXDescriptionAttribute as String,
        kAXValueAttribute as String,
    ]

    func walk(deadline: CaptureDeadline) -> [String] {
        if deadline.isExpired { return [] }
        guard AXIsProcessTrusted() else { return [] }

        guard let root = focusedWindow() else { return [] }

        var seen = Set<String>()
        var collected: [String] = []
        var visited = 0

        // BFS queue of (element, depth).
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        while !queue.isEmpty {
            if deadline.isExpired { break }
            if collected.count >= Self.maxLabels { break }
            if visited >= Self.maxNodesVisited { break }
            let (el, depth) = queue.removeFirst()
            visited += 1

            for attr in attributes {
                if let s = readString(el, attr), let label = normalize(s),
                   seen.insert(label).inserted {
                    collected.append(label)
                    if collected.count >= Self.maxLabels { break }
                }
            }

            if depth < Self.maxDepth, let children = readChildren(el) {
                for child in children {
                    queue.append((child, depth + 1))
                }
            }
        }
        return collected
    }

    private func focusedWindow() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        let s = AXUIElementCopyAttributeValue(
            system, kAXFocusedUIElementAttribute as CFString, &focusedValue
        )
        guard s == .success,
              let focusedValue,
              CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else { return nil }
        let focused = focusedValue as! AXUIElement

        var windowValue: CFTypeRef?
        let ws = AXUIElementCopyAttributeValue(focused, kAXWindowAttribute as CFString, &windowValue)
        guard ws == .success,
              let windowValue,
              CFGetTypeID(windowValue) == AXUIElementGetTypeID() else { return nil }
        return (windowValue as! AXUIElement)
    }

    private func readChildren(_ element: AXUIElement) -> [AXUIElement]? {
        var value: CFTypeRef?
        let s = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
        guard s == .success, let value else { return nil }
        return value as? [AXUIElement]
    }

    private func readString(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        let s = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard s == .success else { return nil }
        return value as? String
    }

    /// Reduce whitespace, drop strings that are pure punctuation/symbols or
    /// longer than the per-label char cap, return nil for empties.
    private func normalize(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        // Drop labels that are very long (likely a paragraph of body text,
        // not a "label"). Truncating would mislead the LLM.
        if trimmed.count > Self.maxLabelChars { return nil }
        // Require at least one alphanumeric character. Pure punctuation
        // ("…", "—") is not informative.
        if !trimmed.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) {
            return nil
        }
        return trimmed
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild -scheme voxline -destination 'platform=macOS,arch=arm64' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add voxline/Context/AXVisibleLabelsWalker.swift
git commit -m "feat(context): add DefaultAXVisibleLabelsWalker BFS (#11)"
```

---

## Task 8: `DefaultContextCaptureService` orchestrator + tests

**Files:**
- Modify: `voxline/Context/ContextCaptureService.swift` (add `DefaultContextCaptureService` below the protocol)
- Create: `voxlineTests/ContextCaptureServiceTests.swift`
- Modify: `voxline.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write the failing tests**

Create `voxlineTests/ContextCaptureServiceTests.swift`:

```swift
import Testing
import Foundation
@testable import voxline

@Suite struct ContextCaptureServiceTests {

    final class FakeFrontmost: FrontmostAppProviding, @unchecked Sendable {
        var bundleID: String?
        var appName: String?
        func frontmostBundleID() -> String? { bundleID }
    }

    final class FakeFieldInspector: FocusedFieldInspecting, @unchecked Sendable {
        var field: FocusedField?
        func inspect() -> FocusedField? { field }
    }

    struct StubProbe: AXContextProbing {
        let result: AXContextProbeResult
        func probe(deadline: CaptureDeadline) -> AXContextProbeResult { result }
    }

    struct StubWalker: AXVisibleLabelsWalking {
        let labels: [String]
        func walk(deadline: CaptureDeadline) -> [String] { labels }
    }

    private func suite() -> UserDefaults {
        let name = "voxline-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func capture_aggregates_app_field_probe_labels_and_vocab() async {
        let front = FakeFrontmost(); front.bundleID = "com.tinyspeck.slackmacgap"; front.appName = "Slack"
        let inspector = FakeFieldInspector(); inspector.field = FocusedField(role: "AXTextArea", subrole: nil)
        let probe = StubProbe(result: AXContextProbeResult(
            windowTitle: "#sales-pipeline — Acme",
            textBeforeCursor: "Hey Kamil,",
            textAfterCursor: nil,
            selectedText: "highlighted"
        ))
        let walker = StubWalker(labels: ["Kamil Szczerba", "Q4 Renewal"])
        let vocab = CustomVocabularyStore(defaults: suite())
        vocab.save(["Cursor", "LangGraph"])

        let svc = DefaultContextCaptureService(
            frontmost: front,
            appNameProvider: { "Slack" },
            fieldInspector: inspector,
            axProbe: probe,
            labelsWalker: walker,
            vocabulary: vocab,
            budgetMs: 150
        )

        let c = await svc.capture()
        #expect(c.appName == "Slack")
        #expect(c.bundleID == "com.tinyspeck.slackmacgap")
        #expect(c.windowTitle == "#sales-pipeline — Acme")
        #expect(c.fieldRole == "AXTextArea")
        #expect(c.isSecureField == false)
        #expect(c.textBeforeCursor == "Hey Kamil,")
        #expect(c.selectedText == "highlighted")
        #expect(c.visibleLabels == ["Kamil Szczerba", "Q4 Renewal"])
        #expect(c.customVocabulary == ["Cursor", "LangGraph"])
        #expect(c.captureNotes.contains("ax-not-trusted") == false)
    }

    @Test func capture_marks_secure_field_and_suppresses_value_lines() async {
        let front = FakeFrontmost(); front.bundleID = "com.1password.1password"
        let inspector = FakeFieldInspector()
        inspector.field = FocusedField(role: "AXTextField", subrole: "AXSecureTextField")
        let probe = StubProbe(result: AXContextProbeResult(
            windowTitle: "Login",
            textBeforeCursor: "hunter2",
            textAfterCursor: nil,
            selectedText: "hunter2"
        ))
        let walker = StubWalker(labels: ["Email", "Password"])
        let vocab = CustomVocabularyStore(defaults: suite())

        let svc = DefaultContextCaptureService(
            frontmost: front,
            appNameProvider: { "1Password" },
            fieldInspector: inspector,
            axProbe: probe,
            labelsWalker: walker,
            vocabulary: vocab,
            budgetMs: 150
        )

        let c = await svc.capture()
        #expect(c.isSecureField == true)
        #expect(c.textBeforeCursor == nil)
        #expect(c.textAfterCursor == nil)
        #expect(c.selectedText == nil)
        #expect(c.windowTitle == "Login")
        #expect(c.visibleLabels == ["Email", "Password"])
        #expect(c.captureNotes.contains("secure-field"))
    }

    @Test func capture_returns_app_only_when_field_inspector_returns_nil() async {
        let front = FakeFrontmost(); front.bundleID = "com.apple.Safari"
        let inspector = FakeFieldInspector(); inspector.field = nil
        let probe = StubProbe(result: AXContextProbeResult())
        let walker = StubWalker(labels: [])
        let vocab = CustomVocabularyStore(defaults: suite())

        let svc = DefaultContextCaptureService(
            frontmost: front,
            appNameProvider: { "Safari" },
            fieldInspector: inspector,
            axProbe: probe,
            labelsWalker: walker,
            vocabulary: vocab,
            budgetMs: 150
        )

        let c = await svc.capture()
        #expect(c.appName == "Safari")
        #expect(c.bundleID == "com.apple.Safari")
        #expect(c.fieldRole == nil)
        #expect(c.windowTitle == nil)
    }

    @Test func capture_records_duration_in_ms() async {
        let front = FakeFrontmost(); front.bundleID = "com.foo"
        let inspector = FakeFieldInspector()
        let probe = StubProbe(result: AXContextProbeResult())
        let walker = StubWalker(labels: [])
        let vocab = CustomVocabularyStore(defaults: suite())

        let svc = DefaultContextCaptureService(
            frontmost: front,
            appNameProvider: { nil },
            fieldInspector: inspector,
            axProbe: probe,
            labelsWalker: walker,
            vocabulary: vocab,
            budgetMs: 150
        )

        let c = await svc.capture()
        #expect(c.captureDurationMs >= 0)
        #expect(c.captureDurationMs <= 200)
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

Run: `xcodebuild -scheme voxline -destination 'platform=macOS,arch=arm64' test -only-testing voxlineTests/ContextCaptureServiceTests 2>&1 | tail -20`
Expected: build failure — `DefaultContextCaptureService` not found.

- [ ] **Step 3: Implement `DefaultContextCaptureService`**

Append to `voxline/Context/ContextCaptureService.swift`:

```swift
import AppKit

/// Default orchestrator. Runs probes in cheapest-first order under a single
/// total time budget. Never throws — returns a partial `CapturedContext`
/// with `captureNotes` describing what was skipped.
struct DefaultContextCaptureService: ContextCapturing {

    let frontmost: FrontmostAppProviding
    let appNameProvider: @Sendable () -> String?
    let fieldInspector: FocusedFieldInspecting
    let axProbe: AXContextProbing
    let labelsWalker: AXVisibleLabelsWalking
    let vocabulary: CustomVocabularyStore
    let budgetMs: Int

    /// Production initializer: resolves `appName` from `NSWorkspace.frontmostApplication`
    /// at call time and wires up the real AX probes.
    init(
        frontmost: FrontmostAppProviding = FrontmostApp(),
        appNameProvider: @escaping @Sendable () -> String? = {
            NSWorkspace.shared.frontmostApplication?.localizedName
        },
        fieldInspector: FocusedFieldInspecting = AXFocusedFieldInspector(),
        axProbe: AXContextProbing = DefaultAXContextProbe(),
        labelsWalker: AXVisibleLabelsWalking = DefaultAXVisibleLabelsWalker(),
        vocabulary: CustomVocabularyStore = CustomVocabularyStore(),
        budgetMs: Int = 150
    ) {
        self.frontmost = frontmost
        self.appNameProvider = appNameProvider
        self.fieldInspector = fieldInspector
        self.axProbe = axProbe
        self.labelsWalker = labelsWalker
        self.vocabulary = vocabulary
        self.budgetMs = budgetMs
    }

    func capture() async -> CapturedContext {
        let deadline = CaptureDeadline(totalMilliseconds: budgetMs)
        var c = CapturedContext.empty

        // Step 1: frontmost app (cheap; no AX).
        c.bundleID = frontmost.frontmostBundleID()
        c.appName = appNameProvider()

        // Step 2: focused field role/subrole + secure-field gate.
        let field = fieldInspector.inspect()
        c.fieldRole = field?.role
        c.fieldSubrole = field?.subrole
        if field?.kind == .secure {
            c.isSecureField = true
            c.captureNotes.append("secure-field")
        }

        // Step 3: probe value-bearing AX attributes — skipped for secure fields.
        if !c.isSecureField && !deadline.isExpired {
            let probe = axProbe.probe(deadline: deadline)
            c.windowTitle = probe.windowTitle
            c.textBeforeCursor = probe.textBeforeCursor
            c.textAfterCursor = probe.textAfterCursor
            c.selectedText = probe.selectedText
        } else if c.isSecureField && !deadline.isExpired {
            // For secure fields we still want the window title (helps the LLM
            // distinguish "login screen" from "in-app password change") but
            // not the value/selection. Re-call the probe and pluck only the
            // non-value field.
            let probe = axProbe.probe(deadline: deadline)
            c.windowTitle = probe.windowTitle
        }

        // Step 4: visible-labels BFS — runs for both normal and secure fields.
        if !deadline.isExpired {
            c.visibleLabels = labelsWalker.walk(deadline: deadline)
        } else {
            c.captureNotes.append("ax-timeout")
        }

        // Step 5: custom vocabulary (cheap; UserDefaults).
        c.customVocabulary = vocabulary.load()

        c.captureDurationMs = deadline.elapsedMilliseconds()
        return c
    }
}
```

- [ ] **Step 4: Add test file to the Xcode project**

Add `voxlineTests/ContextCaptureServiceTests.swift` to `voxline.xcodeproj/project.pbxproj`.

- [ ] **Step 5: Run tests, verify pass**

Run: `xcodebuild -scheme voxline -destination 'platform=macOS,arch=arm64' test -only-testing voxlineTests/ContextCaptureServiceTests 2>&1 | tail -20`
Expected: all 4 tests pass.

- [ ] **Step 6: Commit**

```bash
git add voxline/Context/ContextCaptureService.swift voxlineTests/ContextCaptureServiceTests.swift voxline.xcodeproj/project.pbxproj
git commit -m "feat(context): add DefaultContextCaptureService orchestrator (#11)"
```

---

## Task 9: `LLMService` accepts `CapturedContext`

**Files:**
- Modify: `voxline/Pipeline/PipelineProtocols.swift`
- Modify: `voxline/LLM/LLMService.swift`
- Modify: `voxlineTests/LLMServiceTests.swift`
- Modify: `voxlineTests/CapturePipelineTests.swift` (FakeLLM signature update only)

This is the breaking signature change. Done in one task so the tree stays compilable between commits.

- [ ] **Step 1: Write the new failing test**

Add to `voxlineTests/LLMServiceTests.swift`:

```swift
@Test func cleanup_user_message_includes_context_block_when_context_non_empty() async throws {
    let mock = MockHTTPClient()
    mock.stubResponse = (
        data: #"{"content":[{"type":"text","text":"c"}]}"#.data(using: .utf8)!,
        status: 200
    )
    var settings = AppSettings(defaults: defaultsSuite())
    settings.llmProvider = .anthropic
    let kc = keychain()
    try kc.set("k", forKey: Keychain.Account.anthropic)
    defer { try? kc.deleteAll() }

    let service = LLMService(settings: settings, keychain: kc, http: mock)
    let mode = Mode(bundleID: "*", displayName: "d", prompt: "S", model: nil, temperature: nil)
    var ctx = CapturedContext.empty
    ctx.appName = "Slack"
    ctx.bundleID = "com.tinyspeck.slackmacgap"
    ctx.windowTitle = "#sales"

    _ = try await service.cleanup(transcript: "hi", mode: mode, context: ctx)

    let body = try JSONSerialization.jsonObject(with: try #require(mock.capturedRequest?.httpBody)) as! [String: Any]
    let messages = try #require(body["messages"] as? [[String: Any]])
    let userContent = try #require(messages.first?["content"] as? String)
    #expect(userContent.contains("Raw transcript:\n\"hi\""))
    #expect(userContent.contains("Context:"))
    #expect(userContent.contains("- App: Slack (com.tinyspeck.slackmacgap)"))
    #expect(userContent.contains("- Window: #sales"))
    // System message remains the mode prompt + preamble — unchanged contract.
    let system = try #require(body["system"] as? String)
    #expect(system.contains(LLMService.transcriptionPreamble))
    #expect(system.contains("S"))
    #expect(!system.contains("Context:"))
}

@Test func cleanup_user_message_omits_context_block_when_context_empty() async throws {
    let mock = MockHTTPClient()
    mock.stubResponse = (
        data: #"{"content":[{"type":"text","text":"c"}]}"#.data(using: .utf8)!,
        status: 200
    )
    var settings = AppSettings(defaults: defaultsSuite())
    settings.llmProvider = .anthropic
    let kc = keychain()
    try kc.set("k", forKey: Keychain.Account.anthropic)
    defer { try? kc.deleteAll() }

    let service = LLMService(settings: settings, keychain: kc, http: mock)
    let mode = Mode(bundleID: "*", displayName: "d", prompt: "S", model: nil, temperature: nil)

    _ = try await service.cleanup(transcript: "hi", mode: mode, context: .empty)

    let body = try JSONSerialization.jsonObject(with: try #require(mock.capturedRequest?.httpBody)) as! [String: Any]
    let messages = try #require(body["messages"] as? [[String: Any]])
    let userContent = try #require(messages.first?["content"] as? String)
    #expect(userContent.contains("Raw transcript:\n\"hi\""))
    #expect(!userContent.contains("Context:"))
    #expect(userContent.contains(ContextBlockFormatter.trailingInstruction))
}
```

Update **every existing call** to `service.cleanup(transcript:mode:)` in this file to pass `context: .empty` as the third argument. The previously asserted bodies will keep passing because the formatter produces `Raw transcript:\n"…"\n\n…` and the existing tests only assert on `body["system"]` and substring matches inside `body["model"]` / etc.

- [ ] **Step 2: Run tests to verify failure**

Run: `xcodebuild -scheme voxline -destination 'platform=macOS,arch=arm64' test -only-testing voxlineTests/LLMServiceTests 2>&1 | tail -20`
Expected: build failure — `LLMService.cleanup(transcript:mode:context:)` doesn't exist.

- [ ] **Step 3: Update `LLMServing` protocol**

Edit `voxline/Pipeline/PipelineProtocols.swift`:

Replace:
```swift
protocol LLMServing: Sendable {
    func cleanup(transcript: String, mode: Mode) async throws -> String
}
```

with:

```swift
protocol LLMServing: Sendable {
    func cleanup(transcript: String, mode: Mode, context: CapturedContext) async throws -> String
}
```

- [ ] **Step 4: Update `LLMService.cleanup`**

Edit `voxline/LLM/LLMService.swift` — replace the `cleanup` body to accept `context` and build the user message via `ContextBlockFormatter`:

```swift
func cleanup(transcript: String, mode: Mode, context: CapturedContext) async throws -> String {
    // No transcript → no work. Empty input would otherwise generate a
    // surprise greeting from some models.
    guard !transcript.isEmpty else { return "" }

    let provider = settings.llmProvider
    let account: String
    switch provider {
    case .anthropic: account = Keychain.Account.anthropic
    case .openai:    account = Keychain.Account.openai
    }
    guard
        let key = try keychain.string(forKey: account),
        !key.isEmpty
    else {
        throw LLMError.missingAPIKey
    }

    let model = mode.model ?? settings.llmModel
    let userPrompt = ContextBlockFormatter.format(transcript: transcript, context: context)
    let request = LLMRequest(
        model: model,
        systemPrompt: Self.transcriptionPreamble + "\n" + mode.prompt,
        userPrompt: userPrompt,
        temperature: mode.temperature
    )

    let client: any LLMClient
    switch provider {
    case .anthropic: client = AnthropicClient(apiKey: key, http: http)
    case .openai:    client = OpenAIClient(apiKey: key, http: http)
    }
    return try await client.cleanup(request)
}
```

- [ ] **Step 5: Update `FakeLLM` in CapturePipelineTests**

Edit `voxlineTests/CapturePipelineTests.swift`. Replace the existing `FakeLLM` definition:

```swift
final class FakeLLM: LLMServing, @unchecked Sendable {
    var nextResult: Result<String, Error> = .success("cleaned")
    var calls: [(transcript: String, mode: Mode, context: CapturedContext)] = []
    func cleanup(transcript: String, mode: Mode, context: CapturedContext) async throws -> String {
        calls.append((transcript, mode, context))
        return try nextResult.get()
    }
}
```

If any existing tests in `CapturePipelineTests.swift` access `llm.calls[i].mode` or `.transcript`, those keep working — the tuple just has an extra field.

- [ ] **Step 6: Run tests, verify pass**

Run: `xcodebuild -scheme voxline -destination 'platform=macOS,arch=arm64' test -only-testing voxlineTests/LLMServiceTests -only-testing voxlineTests/CapturePipelineTests 2>&1 | tail -30`
Expected: all `LLMServiceTests` (including the 2 new ones) and all `CapturePipelineTests` pass. The pipeline tests still pass because they're calling the (unchanged) `pipe.finalizeRecording()` entry point — the FakeLLM signature change is internal.

If pipeline tests fail because the pipeline doesn't yet pass `context:`, that's expected — Task 11 wires it. To keep this commit green, *temporarily* have `CapturePipeline` call `llm.cleanup(transcript:, mode:, context: .empty)` (a one-line change in `CapturePipeline.swift`). Task 11 replaces that hardcoded `.empty` with the captured context.

- [ ] **Step 7: Commit**

```bash
git add voxline/Pipeline/PipelineProtocols.swift voxline/LLM/LLMService.swift voxline/Pipeline/CapturePipeline.swift voxlineTests/LLMServiceTests.swift voxlineTests/CapturePipelineTests.swift
git commit -m "feat(llm): LLMService.cleanup accepts CapturedContext (#11)"
```

---

## Task 10: AppLog channel + diagnostic log shape

**Files:**
- Modify: `voxline/Diagnostics/AppLog.swift`

This is a tiny prerequisite for Task 11 (which calls `AppLog.context.debug(...)`). Done in its own commit so each commit builds green.

- [ ] **Step 1: Add the `context` Logger to `AppLog`**

Edit `voxline/Diagnostics/AppLog.swift`. After the `paste` logger, add:

```swift
static let context     = Logger(subsystem: subsystem, category: "context")
```

The final block should look like:

```swift
static let pipeline    = Logger(subsystem: subsystem, category: "pipeline")
static let hotkey      = Logger(subsystem: subsystem, category: "hotkey")
static let audio       = Logger(subsystem: subsystem, category: "audio")
static let whisper     = Logger(subsystem: subsystem, category: "whisper")
static let llm         = Logger(subsystem: subsystem, category: "llm")
static let paste       = Logger(subsystem: subsystem, category: "paste")
static let context     = Logger(subsystem: subsystem, category: "context")
static let permissions = Logger(subsystem: subsystem, category: "permissions")
```

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild -scheme voxline -destination 'platform=macOS,arch=arm64' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add voxline/Diagnostics/AppLog.swift
git commit -m "chore(log): add 'context' AppLog channel (#11)"
```

---

## Task 11: `CapturePipeline` captures context concurrently with recording

**Files:**
- Modify: `voxline/Pipeline/CapturePipeline.swift`
- Modify: `voxlineTests/CapturePipelineTests.swift`

- [ ] **Step 1: Write the failing tests**

Add to `voxlineTests/CapturePipelineTests.swift`:

```swift
final class FakeContextCapture: ContextCapturing, @unchecked Sendable {
    var nextContext = CapturedContext.empty
    var captureCallCount = 0
    func capture() async -> CapturedContext {
        captureCallCount += 1
        return nextContext
    }
}

@Test func finalize_passes_captured_context_to_llm() async {
    let (pipe, state, _, _, llm, _, _, _, _, ctx) = makePipelineWithContext()
    var captured = CapturedContext.empty
    captured.appName = "Slack"
    captured.bundleID = "com.tinyspeck.slackmacgap"
    ctx.nextContext = captured

    await startAndFinalize(pipe, state: state)

    #expect(llm.calls.count == 1)
    #expect(llm.calls.first?.context.appName == "Slack")
    #expect(llm.calls.first?.context.bundleID == "com.tinyspeck.slackmacgap")
    #expect(ctx.captureCallCount == 1)
}

@Test func finalize_with_empty_capture_passes_empty_context() async {
    let (pipe, state, _, _, llm, _, _, _, _, ctx) = makePipelineWithContext()
    ctx.nextContext = .empty

    await startAndFinalize(pipe, state: state)

    #expect(llm.calls.first?.context == CapturedContext.empty)
}
```

Add a `makePipelineWithContext()` helper that mirrors `makePipeline()` but injects a `FakeContextCapture`:

```swift
private func makePipelineWithContext(
    frontmostBundleID: String? = "com.tinyspeck.slackmacgap",
    focusedField: FocusedField? = nil
) -> (pipe: CapturePipeline, state: AppState, capture: FakeCapture, transcriber: FakeTranscriber, llm: FakeLLM, frontmost: FakeFrontmost, inspector: FakeFieldInspector, injector: FakeInjector, history: DictationHistoryStore, contextCapture: FakeContextCapture) {
    let (pipe0, state, capture, transcriber, llm, front, inspector, injector, history) = makePipeline(
        frontmostBundleID: frontmostBundleID, focusedField: focusedField
    )
    // makePipeline returned a pipeline with no context capture; build a fresh
    // one that does. Reuse all other deps.
    let ctx = FakeContextCapture()
    let pipe = CapturePipeline(
        state: state, capture: capture, transcriber: transcriber,
        llm: llm, modes: pipe0.modes, frontmost: front,
        fieldInspector: inspector, injector: injector,
        historyStore: history, contextCapture: ctx
    )
    return (pipe, state, capture, transcriber, llm, front, inspector, injector, history, ctx)
}
```

- [ ] **Step 2: Run tests to verify failure**

Run: `xcodebuild -scheme voxline -destination 'platform=macOS,arch=arm64' test -only-testing voxlineTests/CapturePipelineTests 2>&1 | tail -20`
Expected: build failure — `CapturePipeline.init` doesn't accept `contextCapture:`.

- [ ] **Step 3: Update `CapturePipeline`**

Edit `voxline/Pipeline/CapturePipeline.swift`. Add an injected `ContextCapturing`, kick off the capture task in `startRecording()`, await it before the LLM call in `finalizeRecording()`.

Add stored property and init param:

```swift
private let contextCapture: ContextCapturing
private var contextTask: Task<CapturedContext, Never>?
```

Update the initializer signature (add `contextCapture: ContextCapturing` after `historyStore`):

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
    contextCapture: ContextCapturing
) {
    self.state = state
    self.capture = capture
    self.transcriber = transcriber
    self.llm = llm
    self.modes = modes
    self.frontmost = frontmost
    self.fieldInspector = fieldInspector
    self.injector = injector
    self.historyStore = historyStore
    self.contextCapture = contextCapture

    capture.onLevel = { [weak self] level in
        Task { @MainActor in
            guard let self else { return }
            self.state.audioLevel = level
            if level > self.state.lastPeakLevel {
                self.state.lastPeakLevel = level
            }
        }
    }
}
```

In `startRecording()`, immediately after `try capture.start()` succeeds (right after the `AppLog.pipeline.debug("recording started")` line), kick off the capture task:

```swift
let captor = contextCapture
contextTask = Task.detached(priority: .userInitiated) {
    await captor.capture()
}
```

In `finalizeRecording()`, replace the LLM call site (currently `cleaned = try await llm.cleanup(transcript: transcript, mode: mode)`) with:

```swift
let context = await contextTask?.value ?? .empty
contextTask = nil
AppLog.context.debug("context: app=\(context.appName ?? "nil", privacy: .public) bundle=\(context.bundleID ?? "nil", privacy: .public) secure=\(context.isSecureField, privacy: .public) labels=\(context.visibleLabels.count, privacy: .public) durationMs=\(context.captureDurationMs, privacy: .public) notes=\(context.captureNotes.joined(separator: ","), privacy: .public)")

let cleaned: String
let cleanupInterval = signposter.beginInterval("llm", id: sessionID)
let cleanupStart = Date()
do {
    cleaned = try await llm.cleanup(transcript: transcript, mode: mode, context: context)
    signposter.endInterval("llm", cleanupInterval)
}
```

(Replace the original `cleaned = try await llm.cleanup(transcript: transcript, mode: mode)` line; the remaining `} catch ...` blocks stay.)

Also handle the early-return paths so a queued `contextTask` doesn't outlive a non-LLM exit. At every `return` inside `finalizeRecording()` that occurs before the LLM block, add:

```swift
contextTask?.cancel()
contextTask = nil
```

The specific lines to update: the silent-capture-detector return, the empty-samples return, the transcribe-error return, the empty-transcript return, and the no-mode return. (The Task isn't cancellable for actual work — `DefaultContextCaptureService.capture` doesn't check cancellation — but cancelling drops the reference so it won't block GC.)

- [ ] **Step 4: Also remove the temporary `.empty` from Task 9**

If you wired `context: .empty` into `CapturePipeline.swift` in Task 9 Step 6 as a stopgap, Step 3 above replaces it with the real captured context. Verify the diff shows no `context: .empty` left in `CapturePipeline.swift`.

- [ ] **Step 5: Update the existing `makePipeline()` to pass a context capture**

In `voxlineTests/CapturePipelineTests.swift`, edit `makePipeline()` so its `CapturePipeline(...)` construction passes `contextCapture: FakeContextCapture()`. The existing test cases don't care about context but the type must compile.

- [ ] **Step 6: Run all pipeline tests, verify pass**

Run: `xcodebuild -scheme voxline -destination 'platform=macOS,arch=arm64' test -only-testing voxlineTests/CapturePipelineTests 2>&1 | tail -30`
Expected: every existing test still passes + the 2 new tests pass.

- [ ] **Step 7: Commit**

```bash
git add voxline/Pipeline/CapturePipeline.swift voxlineTests/CapturePipelineTests.swift
git commit -m "feat(pipeline): capture context concurrently during recording (#11)"
```

---

## Task 12: Wire `DefaultContextCaptureService` into `AppCoordinator`

**Files:**
- Modify: `voxline/voxlineApp.swift`

- [ ] **Step 1: Construct the service and pass it into `CapturePipeline`**

Edit `voxline/voxlineApp.swift`. Inside `AppCoordinator.buildServices`, after `let fieldInspector = AXFocusedFieldInspector()` and before the `CapturePipeline(...)` construction, add:

```swift
let contextCapture = DefaultContextCaptureService(
    frontmost: frontmost,
    fieldInspector: fieldInspector
    // appNameProvider, axProbe, labelsWalker, vocabulary, budgetMs default to production values
)
```

Update the `CapturePipeline(...)` call to pass the service:

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

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild -scheme voxline -destination 'platform=macOS,arch=arm64' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Run the full test suite to confirm nothing else broke**

Run: `xcodebuild -scheme voxline -destination 'platform=macOS,arch=arm64' test 2>&1 | tail -10`
Expected: all tests pass (or only the pre-existing failures, if any).

- [ ] **Step 4: Commit**

```bash
git add voxline/voxlineApp.swift
git commit -m "feat(app): wire DefaultContextCaptureService into AppCoordinator (#11)"
```

---

## Task 13: Settings UI for the custom-vocabulary text field

**Files:**
- Modify: `voxline/Settings/GeneralSettingsViewModel.swift`
- Modify: `voxline/Settings/SettingsView.swift`
- Modify: `voxlineTests/GeneralSettingsViewModelTests.swift`

The vocabulary is read on every dictation by `DefaultContextCaptureService` (via its own `CustomVocabularyStore`). The Settings UI is the only producer of changes — there's no need to thread the value through `GeneralSettingsApplier`. Saves go straight to `CustomVocabularyStore` from the view model.

- [ ] **Step 1: Write the failing test**

Add to `voxlineTests/GeneralSettingsViewModelTests.swift`:

```swift
@Test func customVocabularyText_load_returns_persisted_terms_joined() {
    let defaults = TestSupport.suiteDefaults()
    let vocab = CustomVocabularyStore(defaults: defaults)
    vocab.save(["Cursor", "LangGraph", "canonical_title"])
    let vm = GeneralSettingsViewModel(
        settings: AppSettings(defaults: defaults),
        applier: NoopApplier(),
        deviceEnumerator: { [] },
        loginItemService: LoginItemService(),
        vocabulary: vocab
    )
    #expect(vm.customVocabularyText == "Cursor, LangGraph, canonical_title")
}

@Test func customVocabularyText_setting_persists_through_store() {
    let defaults = TestSupport.suiteDefaults()
    let vocab = CustomVocabularyStore(defaults: defaults)
    let vm = GeneralSettingsViewModel(
        settings: AppSettings(defaults: defaults),
        applier: NoopApplier(),
        deviceEnumerator: { [] },
        loginItemService: LoginItemService(),
        vocabulary: vocab
    )
    vm.customVocabularyText = "Cursor,LangGraph\ncanonical_title"
    #expect(vocab.load() == ["Cursor", "LangGraph", "canonical_title"])
}
```

If `TestSupport.suiteDefaults()` and `NoopApplier` don't already exist in the test file, model them on the patterns used in other test files (UUID-named UserDefaults suite, struct conforming to `GeneralSettingsApplier` with an empty `apply`).

- [ ] **Step 2: Run tests to verify failure**

Run: `xcodebuild -scheme voxline -destination 'platform=macOS,arch=arm64' test -only-testing voxlineTests/GeneralSettingsViewModelTests 2>&1 | tail -20`
Expected: build failure — `customVocabularyText` and the new init parameter don't exist.

- [ ] **Step 3: Add `customVocabularyText` to the view model**

Edit `voxline/Settings/GeneralSettingsViewModel.swift`. Add a stored property and persistence wiring:

After the `var provider: LLMProvider { didSet { if loaded { commit() } } }` line, add:

```swift
var customVocabularyText: String {
    didSet {
        guard loaded, oldValue != customVocabularyText else { return }
        let terms = CustomVocabularyStore.parse(customVocabularyText)
        vocabulary.save(terms)
    }
}
```

Add a stored vocabulary property:

```swift
private let vocabulary: CustomVocabularyStore
```

Add `vocabulary:` to both initializers (convenience and designated). Default it to `CustomVocabularyStore()`:

```swift
convenience init(
    settings: AppSettings = AppSettings(),
    applier: GeneralSettingsApplier,
    deviceEnumerator: @escaping () -> [AudioDevice] = AudioDeviceEnumerator.inputDevices,
    vocabulary: CustomVocabularyStore = CustomVocabularyStore()
) {
    self.init(
        settings: settings,
        applier: applier,
        deviceEnumerator: deviceEnumerator,
        loginItemService: LoginItemService(),
        vocabulary: vocabulary
    )
}

init(
    settings: AppSettings = AppSettings(),
    applier: GeneralSettingsApplier,
    deviceEnumerator: @escaping () -> [AudioDevice] = AudioDeviceEnumerator.inputDevices,
    loginItemService: LoginItemService,
    vocabulary: CustomVocabularyStore = CustomVocabularyStore()
) {
    self.settings = settings
    self.applier = applier
    self.deviceEnumerator = deviceEnumerator
    self.loginItemService = loginItemService
    self.vocabulary = vocabulary
    self.chord = settings.hotkeyChord
    self.audioInputDeviceUID = settings.audioInputDeviceUID
    self.whisperModel = settings.whisperModel
    self.playHotkeySounds = settings.playHotkeySounds
    self.provider = settings.llmProvider
    self.customVocabularyText = vocabulary.load().joined(separator: ", ")
    let initialStatus = loginItemService.status
    self.loginItemStatus = initialStatus
    self.launchAtLogin = (initialStatus == .enabled)
    self.devices = deviceEnumerator()
    self.loaded = true
    self.deviceListener = AudioDeviceListener { [weak self] in
        MainActor.assumeIsolated { self?.refreshDevices() }
    }
}
```

In `resetToDefaults()`, also clear the vocabulary text (and persist the empty list):

```swift
func resetToDefaults() {
    loaded = false
    chord = .default
    audioInputDeviceUID = nil
    whisperModel = .default
    playHotkeySounds = true
    provider = .anthropic
    customVocabularyText = ""
    vocabulary.save([])
    loaded = true
    commit()
}
```

- [ ] **Step 4: Add the Settings section**

Edit `voxline/Settings/SettingsView.swift`. Add a new `Section("Custom vocabulary")` immediately above the `Section("Feedback")` block:

```swift
Section("Custom vocabulary") {
    TextEditor(text: $generalVM.customVocabularyText)
        .font(.body)
        .frame(minHeight: 60)
    Text("Comma- or newline-separated. Helps the cleanup model spell names, acronyms, and product terms correctly.")
        .foregroundStyle(.secondary)
        .font(.callout)
}
```

(If the file has a `SettingsAnchor` enum, add `case customVocabulary` and `.id(SettingsAnchor.customVocabulary)` on the section — match the pattern used by other sections.)

- [ ] **Step 5: Run tests, verify pass**

Run: `xcodebuild -scheme voxline -destination 'platform=macOS,arch=arm64' test -only-testing voxlineTests/GeneralSettingsViewModelTests 2>&1 | tail -20`
Expected: all tests pass.

- [ ] **Step 6: Smoke the UI**

Run: `xcodebuild -scheme voxline -destination 'platform=macOS,arch=arm64' build && open build/Debug/voxline.app` (or run from Xcode).
Open Settings → confirm "Custom vocabulary" section is visible, accepts text input, and the entered terms persist across an app relaunch.

- [ ] **Step 7: Commit**

```bash
git add voxline/Settings/GeneralSettingsViewModel.swift voxline/Settings/SettingsView.swift voxlineTests/GeneralSettingsViewModelTests.swift
git commit -m "feat(settings): add Custom vocabulary section (#11)"
```

---

## Task 14: End-to-end smoke matrix + feature roadmap update

**Files:**
- Modify: `docs/insertion-smoke-matrix.md`
- Modify: `docs/features.md`

- [ ] **Step 1: Add a "Context captured" column to the smoke matrix**

Open `docs/insertion-smoke-matrix.md`. Add a column or a new section per target app (Mail, Slack, Cursor, Safari, Notes, Terminal). For each, document the expected Context lines:

- **Frontmost app present:** `- App: <name> (<bundle id>)`
- **Window title:** present iff the app exposes one via AX (Notes/Mail yes, Terminal often empty).
- **Field role:** `- Field: AXTextField` / `AXTextArea` / `AXSearchField` depending on the focused element.
- **Selected text:** present when a selection exists.
- **Text before cursor:** present when the focused field has a value and the caret is past character 0.
- **Visible labels:** non-empty for native AppKit apps; possibly empty/short for Electron (Slack, Cursor).
- **Custom vocabulary:** present iff the user has saved any global terms.
- **Secure field (login screen):** confirm value-bearing lines are suppressed; `- Field: secure` appears.

Walk the table manually with `Console.app` filtering on `subsystem == "com.voxline.app" AND category == "context"` to confirm each session's `AppLog.context.debug(...)` line matches expectations.

- [ ] **Step 2: Mark feature #11 done in `docs/features.md`**

Edit `docs/features.md`. Replace the `11. [ ]` line with:

```
11. [x] **Context-aware formatting** — Adjusts output based on where the user is typing: email reply, Slack message, document, code comment, task note, or search box.
```

- [ ] **Step 3: Run the full test suite once more**

Run: `xcodebuild -scheme voxline -destination 'platform=macOS,arch=arm64' test 2>&1 | tail -10`
Expected: all tests pass.

- [ ] **Step 4: Commit**

```bash
git add docs/insertion-smoke-matrix.md docs/features.md
git commit -m "docs(features): mark context-aware formatting (#11) done"
```

---

## Self-Review Notes

- **Spec coverage:** Each spec section maps to tasks — `Architecture` → Tasks 5–8; `Data flow` → Task 11; `Data model` → Task 2; `Capture flow and time budget` → Tasks 4, 6, 7, 8; `Prompt format` → Task 3; `Custom vocabulary` → Tasks 1, 13; `Error handling` → covered across Tasks 8, 11; `Testing` → Tasks 1–4, 8, 9, 11, 13, 14; `Diagnostics` → Tasks 10, 11.
- **Placeholder scan:** No "TBD"/"TODO" entries. Every code step shows the actual code. Every test step shows the actual test code.
- **Type consistency:** `CapturedContext` shape is defined in Task 2 and used identically in Tasks 3, 8, 9, 10. `ContextCapturing.capture()` signature defined in Task 5, implemented in Task 8, consumed in Task 10. `LLMServing.cleanup(transcript:mode:context:)` defined in Task 9, consumed in Task 10. `CustomVocabularyStore` API (`load`/`save`/`parse`) defined in Task 1, used in Tasks 8 and 13.
- **AX-realimpl test note:** `DefaultAXContextProbe` and `DefaultAXVisibleLabelsWalker` are not unit-tested because they call real cross-process AX APIs. Coverage comes from the orchestrator tests in Task 8 (which use stub probes) plus the manual smoke matrix in Task 14.
- **Build-green between commits:** Task 10 (AppLog channel) lands before Task 11 (CapturePipeline integration) so every commit builds cleanly. Likewise, Task 9 includes a temporary `context: .empty` patch in `CapturePipeline.swift` to keep the tree green until Task 11 replaces it with real captured context.
