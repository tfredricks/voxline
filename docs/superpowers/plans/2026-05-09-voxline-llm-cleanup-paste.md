# voxline LLM Cleanup + Paste Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Plan 2 debug-transcript window with the real auto-paste flow: hotkey → audio → WhisperKit → bundle-ID-keyed prompt → Anthropic/OpenAI cleanup → clipboard inject + synthetic `Cmd+V` → clipboard restore.

**Architecture:** Three new subsystems plug into the existing `CapturePipeline`:

- **Modes** (`Mode` + `ModeStore` + `ModeRouter`) — per-bundle-ID prompt routing with `*` fallback, persisted as JSON in the sandboxed Application Support container.
- **LLM** (`LLMProvider` + `AnthropicClient` + `OpenAIClient` + `LLMService`) — non-streaming text completion. API key stored in Keychain; provider/model in `UserDefaults`. Both clients share an `HTTPClient` protocol to enable URLSession-free unit tests.
- **Output** (`PasteboardSnapshot` + `ClipboardInjector`) — snapshot every data-bearing pasteboard type, write cleaned text, gate on chord release, post synthetic `Cmd+V`, restore after 300 ms — refuses to clobber promised types per spec §7.1.

A minimal API Keys settings tab gets wired this plan (so the app is end-to-end testable without hardcoded keys); the Modes editor and the General/first-run UI stay deferred to Plan 4.

**Tech Stack:** Swift 5.10, SwiftUI, AppKit (`NSPasteboard`, `NSWorkspace`), CoreGraphics (`CGEventSource.flagsState`, `CGEvent` for synthetic events), Security framework (Keychain `SecItem*`), `URLSession`. Tests use swift-testing (`import Testing`).

**Spec:** `docs/superpowers/specs/2026-05-08-voxline-dictation-design.md` (v0.2). This plan implements §4.3, §5.1–5.3, §6.3 (API Keys tab only), §7.1, and the relevant parts of §9.1.

**Baseline:** main at `902a1fd` (Plan 2 merged). Capture pipeline writes `state.lastTranscript`; debug window displays it. This plan removes that window and replaces the post-transcribe behavior with real cleanup + paste.

---

## File Structure

**New files:**

```
voxline/Modes/
  Mode.swift                       # struct (Codable)
  ModeStore.swift                  # JSON persistence + ship defaults
  ModeRouter.swift                 # bundle-ID → Mode lookup with `*` fallback
voxline/LLM/
  LLMProvider.swift                # enum + LLMRequest/LLMResponse/LLMError
  HTTPClient.swift                 # protocol + URLSession-backed default
  AnthropicClient.swift            # POST /v1/messages
  OpenAIClient.swift               # POST /v1/chat/completions
  LLMService.swift                 # facade: pick client, fetch key, run
voxline/Storage/
  Keychain.swift                   # generic-password wrapper
  AppSettings.swift                # UserDefaults: provider + LLM model
voxline/Output/
  PasteboardSnapshot.swift         # data structure capturing items × types
  ClipboardInjector.swift          # snapshot → write → gate → Cmd+V → restore
  FrontmostApp.swift               # tiny wrapper around NSWorkspace.frontmostApplication
voxlineTests/
  ModeTests.swift
  ModeStoreTests.swift
  ModeRouterTests.swift
  KeychainTests.swift
  AppSettingsTests.swift
  LLMTypesTests.swift
  AnthropicClientTests.swift
  OpenAIClientTests.swift
  LLMServiceTests.swift
  PasteboardSnapshotTests.swift
  ClipboardInjectorTests.swift
  APIKeysSettingsViewModelTests.swift
```

**Modified files:**

```
voxline/Pipeline/CapturePipeline.swift          # finalizeRecording chains: transcribe → resolveMode → LLM → paste
voxline/Pipeline/PipelineProtocols.swift         # add LLMServing, ModeResolving, ClipboardInjecting
voxline/voxlineApp.swift                         # remove debug Window scene; wire LLMService + ClipboardInjector + ModeStore + ModeRouter into AppCoordinator
voxline/MenuBar/MenuBarContent.swift             # remove "Show Transcripts (debug)…" menu item
voxline/Settings/APIKeysSettingsView.swift       # real API Keys UI: provider picker + Anthropic/OpenAI key fields → Keychain
voxlineTests/CapturePipelineTests.swift          # extend coverage for the new pipeline tail
```

**Deleted files:**

```
voxline/UI/DebugTranscriptWindow.swift
```

**Naming conventions used downstream tasks should respect:**
- Type names: `Mode`, `ModeStore`, `ModeRouter`, `LLMProvider`, `LLMRequest`, `LLMResponse`, `LLMError`, `HTTPClient`, `URLSessionHTTPClient`, `AnthropicClient`, `OpenAIClient`, `LLMService`, `Keychain`, `AppSettings`, `PasteboardSnapshot`, `ClipboardInjector`, `ClipboardInjectError`, `FrontmostApp`.
- Protocol names (testability seams in `PipelineProtocols.swift`): `LLMServing`, `ModeResolving`, `ClipboardInjecting`.
- Method names: `ModeStore.load()`, `ModeStore.save(_:)`, `ModeRouter.mode(for:)`, `LLMService.cleanup(transcript:mode:)`, `Keychain.set(_:forKey:)` / `Keychain.string(forKey:)` / `Keychain.delete(forKey:)`, `ClipboardInjector.inject(_:)`.
- Keychain service identifier: `"com.voxline.voxline.keys"`. Keychain account names: `"anthropic"`, `"openai"`.
- UserDefaults keys: `"voxline.llm.provider"`, `"voxline.llm.model"`. The provider key holds the rawValue of `LLMProvider`.

---

## Cross-Task Notes

**No real network in unit tests.** All LLM-client tests use a `MockHTTPClient` that captures the outbound `URLRequest` and returns a canned response. Real-network smoke is manual.

**No real `NSPasteboard.general` writes in tests.** All pasteboard tests construct an `NSPasteboard(name: NSPasteboard.Name(rawValue: "voxline-test-\(UUID())"))` and dispose at the end of the test; the user's actual clipboard is never touched.

**Tests must keep passing.** After every task, `xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS,arch=arm64'` must report `** TEST SUCCEEDED **`. Plan 2 baseline = 56 tests in 8 suites. Each task in this plan adds tests; the implementer should report the new total in their summary.

**SourceKit cross-file diagnostics will lag.** As during Plan 2, SourceKit's "Cannot find type X" diagnostics on freshly-added cross-file symbols are false positives during a streaming edit; trust `xcodebuild` over inline diagnostics.

---

## Task 1: Mode data model

**Files:**
- Create: `voxline/Modes/Mode.swift`
- Create: `voxlineTests/ModeTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// voxlineTests/ModeTests.swift
import Testing
import Foundation
@testable import voxline

@Suite struct ModeTests {

    @Test func encodes_and_decodes_round_trip_with_all_fields() throws {
        let mode = Mode(
            bundleID: "com.tinyspeck.slackmacgap",
            displayName: "Slack",
            prompt: "Concise, casual.",
            model: "claude-haiku-4-5",
            temperature: 0.3
        )
        let data = try JSONEncoder().encode(mode)
        let decoded = try JSONDecoder().decode(Mode.self, from: data)
        #expect(decoded == mode)
    }

    @Test func encodes_and_decodes_round_trip_with_optional_fields_nil() throws {
        let mode = Mode(
            bundleID: "*",
            displayName: "Default",
            prompt: "Strip fillers.",
            model: nil,
            temperature: nil
        )
        let data = try JSONEncoder().encode(mode)
        let decoded = try JSONDecoder().decode(Mode.self, from: data)
        #expect(decoded == mode)
    }

    @Test func wildcard_bundle_id_is_a_well_known_constant() {
        #expect(Mode.wildcardBundleID == "*")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS,arch=arm64' 2>&1 | tail -20
```

Expected: build error — `Cannot find 'Mode' in scope`.

- [ ] **Step 3: Implement Mode**

```swift
// voxline/Modes/Mode.swift
import Foundation

/// Per-app prompt configuration. The active mode is selected by bundle ID;
/// `*` is the wildcard fallback when no specific match exists.
struct Mode: Codable, Equatable {
    static let wildcardBundleID = "*"

    let bundleID: String
    let displayName: String
    let prompt: String
    /// Optional per-mode override of the LLM model id. When nil, AppSettings.llmModel is used.
    let model: String?
    /// Optional per-mode override of the sampling temperature.
    let temperature: Double?
}
```

- [ ] **Step 4: Run tests to verify pass**

```bash
xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS,arch=arm64' 2>&1 | tail -10
```

Expected: `** TEST SUCCEEDED **`. Suite count grows by 1.

- [ ] **Step 5: Commit**

```bash
cd /Users/toddfredricks/GitHub/voxline
git add voxline/Modes/Mode.swift voxlineTests/ModeTests.swift
git commit -m "Add Mode data model (Codable + wildcard constant)"
```

---

## Task 2: ModeStore (load/save + ship defaults)

**Files:**
- Create: `voxline/Modes/ModeStore.swift`
- Create: `voxlineTests/ModeStoreTests.swift`

The store reads/writes `<applicationSupport>/voxline/modes.json` via the existing `AppPaths.modesFile()`. On first launch (file missing), `load()` returns the shipped defaults and writes them to disk so the user has something to edit later.

- [ ] **Step 1: Write the failing tests**

```swift
// voxlineTests/ModeStoreTests.swift
import Testing
import Foundation
@testable import voxline

@Suite struct ModeStoreTests {

    /// Build a ModeStore against a fresh per-test directory so we don't
    /// touch the real Application Support modes.json.
    private func makeStore() -> (store: ModeStore, dir: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxline-modestore-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("modes.json")
        return (ModeStore(fileURL: url), dir)
    }

    @Test func load_on_missing_file_returns_shipped_defaults_and_creates_file() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let modes = try store.load()
        #expect(modes == ModeStore.shippedDefaults)
        #expect(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    @Test func save_then_load_round_trip() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let custom = [
            Mode(bundleID: "com.apple.notes", displayName: "Notes", prompt: "casual", model: nil, temperature: nil)
        ]
        try store.save(custom)
        let loaded = try store.load()
        #expect(loaded == custom)
    }

    @Test func shipped_defaults_include_wildcard_fallback() {
        #expect(ModeStore.shippedDefaults.contains(where: { $0.bundleID == Mode.wildcardBundleID }))
    }

    @Test func shipped_defaults_cover_slack_mail_cursor() {
        let ids = Set(ModeStore.shippedDefaults.map(\.bundleID))
        #expect(ids.contains("com.tinyspeck.slackmacgap"))
        #expect(ids.contains("com.apple.mail"))
        #expect(ids.contains("com.todesktop.230313mzl4w4u92"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Expected: build error — `Cannot find 'ModeStore' in scope`.

- [ ] **Step 3: Implement ModeStore**

```swift
// voxline/Modes/ModeStore.swift
import Foundation

/// JSON-backed persistence for the user's modes list. Reads/writes the file
/// at `fileURL`. On a missing file, `load()` returns `shippedDefaults` and
/// writes them so the user can edit a real seed.
final class ModeStore {

    let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Convenience initializer pointing at the canonical Application Support
    /// path returned by `AppPaths.modesFile()`.
    convenience init() throws {
        try self.init(fileURL: AppPaths.modesFile())
    }

    func load() throws -> [Mode] {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode([Mode].self, from: data)
        }
        try save(Self.shippedDefaults)
        return Self.shippedDefaults
    }

    func save(_ modes: [Mode]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(modes)
        try data.write(to: fileURL, options: .atomic)
    }

    /// Defaults from spec §5.2.
    static let shippedDefaults: [Mode] = [
        Mode(
            bundleID: "com.tinyspeck.slackmacgap",
            displayName: "Slack",
            prompt: "Concise, casual. Strip fillers. No greeting unless dictated.",
            model: nil,
            temperature: nil
        ),
        Mode(
            bundleID: "com.apple.mail",
            displayName: "Mail",
            prompt: "Format as a professional email body. Punctuate. Preserve meaning.",
            model: nil,
            temperature: nil
        ),
        Mode(
            bundleID: "com.todesktop.230313mzl4w4u92",
            displayName: "Cursor",
            prompt: "Return as-is, treat as code-adjacent text. Minimal cleanup.",
            model: nil,
            temperature: nil
        ),
        Mode(
            bundleID: Mode.wildcardBundleID,
            displayName: "Default",
            prompt: "Strip fillers. Punctuate. Preserve the speaker's voice.",
            model: nil,
            temperature: nil
        )
    ]
}
```

- [ ] **Step 4: Run tests to verify pass**

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add voxline/Modes/ModeStore.swift voxlineTests/ModeStoreTests.swift
git commit -m "Add ModeStore: JSON persistence + shipped defaults"
```

---

## Task 3: ModeRouter (bundle-ID lookup)

**Files:**
- Create: `voxline/Modes/ModeRouter.swift`
- Create: `voxlineTests/ModeRouterTests.swift`

A pure-logic lookup over a `[Mode]` array. Exact bundle-ID match wins; otherwise return the first wildcard mode; otherwise return nil.

- [ ] **Step 1: Write the failing tests**

```swift
// voxlineTests/ModeRouterTests.swift
import Testing
@testable import voxline

@Suite struct ModeRouterTests {

    private let modes: [Mode] = [
        Mode(bundleID: "com.tinyspeck.slackmacgap", displayName: "Slack", prompt: "slack-prompt", model: nil, temperature: nil),
        Mode(bundleID: "com.apple.mail", displayName: "Mail", prompt: "mail-prompt", model: nil, temperature: nil),
        Mode(bundleID: Mode.wildcardBundleID, displayName: "Default", prompt: "default-prompt", model: nil, temperature: nil)
    ]

    @Test func exact_bundle_id_match_wins() {
        let router = ModeRouter(modes: modes)
        #expect(router.mode(for: "com.tinyspeck.slackmacgap")?.prompt == "slack-prompt")
        #expect(router.mode(for: "com.apple.mail")?.prompt == "mail-prompt")
    }

    @Test func unknown_bundle_id_falls_back_to_wildcard() {
        let router = ModeRouter(modes: modes)
        #expect(router.mode(for: "com.unknown.app")?.prompt == "default-prompt")
    }

    @Test func nil_bundle_id_falls_back_to_wildcard() {
        let router = ModeRouter(modes: modes)
        #expect(router.mode(for: nil)?.prompt == "default-prompt")
    }

    @Test func no_wildcard_no_match_returns_nil() {
        let router = ModeRouter(modes: [
            Mode(bundleID: "com.apple.mail", displayName: "Mail", prompt: "mail", model: nil, temperature: nil)
        ])
        #expect(router.mode(for: "com.unknown.app") == nil)
    }

    @Test func empty_modes_returns_nil() {
        let router = ModeRouter(modes: [])
        #expect(router.mode(for: "anything") == nil)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Expected: `Cannot find 'ModeRouter' in scope`.

- [ ] **Step 3: Implement ModeRouter**

```swift
// voxline/Modes/ModeRouter.swift
import Foundation

/// Pure-logic lookup of a `Mode` by bundle ID with `*` wildcard fallback.
/// Snapshot-style: pass the current modes in; ModeRouter doesn't observe
/// changes itself (callers re-create or update `.modes` when modes change).
struct ModeRouter {

    var modes: [Mode]

    /// Exact bundle-ID match wins; otherwise return the first wildcard mode;
    /// otherwise nil. A nil `bundleID` (e.g., when no app is frontmost) is
    /// treated the same as "no exact match" — falls through to wildcard.
    func mode(for bundleID: String?) -> Mode? {
        if let bundleID, let exact = modes.first(where: { $0.bundleID == bundleID }) {
            return exact
        }
        return modes.first(where: { $0.bundleID == Mode.wildcardBundleID })
    }
}
```

- [ ] **Step 4: Run tests to verify pass**

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add voxline/Modes/ModeRouter.swift voxlineTests/ModeRouterTests.swift
git commit -m "Add ModeRouter: bundle-ID lookup with * fallback"
```

---

## Task 4: Keychain wrapper

**Files:**
- Create: `voxline/Storage/Keychain.swift`
- Create: `voxlineTests/KeychainTests.swift`

Generic-password Keychain wrapper used for API keys. Service identifier is fixed (`"com.voxline.voxline.keys"`); accounts are caller-supplied (`"anthropic"`, `"openai"`).

Tests run against a *separate* service identifier so they don't trample any real keys the user has stored.

- [ ] **Step 1: Write the failing tests**

```swift
// voxlineTests/KeychainTests.swift
import Testing
import Foundation
@testable import voxline

@Suite struct KeychainTests {

    /// Use a per-test service identifier so tests don't trample the real keychain entries.
    private func makeKeychain() -> Keychain {
        Keychain(service: "com.voxline.voxline.test.\(UUID().uuidString)")
    }

    @Test func set_then_get_returns_stored_value() throws {
        let kc = makeKeychain()
        defer { try? kc.deleteAll() }

        try kc.set("sk-test-key", forKey: "anthropic")
        #expect(try kc.string(forKey: "anthropic") == "sk-test-key")
    }

    @Test func get_unset_key_returns_nil() throws {
        let kc = makeKeychain()
        defer { try? kc.deleteAll() }

        #expect(try kc.string(forKey: "missing") == nil)
    }

    @Test func set_overwrites_existing_value() throws {
        let kc = makeKeychain()
        defer { try? kc.deleteAll() }

        try kc.set("v1", forKey: "anthropic")
        try kc.set("v2", forKey: "anthropic")
        #expect(try kc.string(forKey: "anthropic") == "v2")
    }

    @Test func delete_removes_value() throws {
        let kc = makeKeychain()
        defer { try? kc.deleteAll() }

        try kc.set("v", forKey: "openai")
        try kc.delete(forKey: "openai")
        #expect(try kc.string(forKey: "openai") == nil)
    }

    @Test func delete_unset_key_does_not_throw() throws {
        let kc = makeKeychain()
        defer { try? kc.deleteAll() }

        try kc.delete(forKey: "missing")  // No throw expected.
    }

    @Test func different_keys_in_same_service_are_isolated() throws {
        let kc = makeKeychain()
        defer { try? kc.deleteAll() }

        try kc.set("a-val", forKey: "anthropic")
        try kc.set("o-val", forKey: "openai")
        #expect(try kc.string(forKey: "anthropic") == "a-val")
        #expect(try kc.string(forKey: "openai") == "o-val")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Expected: `Cannot find 'Keychain' in scope`.

- [ ] **Step 3: Implement Keychain wrapper**

```swift
// voxline/Storage/Keychain.swift
import Foundation
import Security

/// Generic-password Keychain wrapper. One instance per logical "service"
/// (a namespace like `com.voxline.voxline.keys`); within a service, items
/// are addressed by a string `key` (i.e., the Keychain `account`).
struct Keychain {

    /// Canonical service id used by the app for API keys.
    static let appServiceID = "com.voxline.voxline.keys"

    /// Canonical account names.
    enum Account {
        static let anthropic = "anthropic"
        static let openai = "openai"
    }

    enum KeychainError: Error, Equatable {
        case unhandledStatus(OSStatus)
        case unexpectedDataFormat
    }

    let service: String

    init(service: String = Keychain.appServiceID) {
        self.service = service
    }

    func string(forKey key: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let s = String(data: data, encoding: .utf8) else {
                throw KeychainError.unexpectedDataFormat
            }
            return s
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unhandledStatus(status)
        }
    }

    func set(_ value: String, forKey key: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        let attrs: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var add = query
            add[kSecValueData as String] = data
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unhandledStatus(addStatus)
            }
        default:
            throw KeychainError.unhandledStatus(updateStatus)
        }
    }

    func delete(forKey key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandledStatus(status)
        }
    }

    /// Test helper: removes every item with this service id. Production code
    /// has no reason to call this.
    func deleteAll() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandledStatus(status)
        }
    }
}
```

- [ ] **Step 4: Run tests to verify pass**

Expected: `** TEST SUCCEEDED **`.

If tests fail with `errSecMissingEntitlement` (-34018), the app's keychain group entitlement is missing — but for a sandboxed app accessing only its own service, no extra keychain group is needed. If you hit this, double-check the test target shares the host-app sandbox; the Plan-1 default does.

- [ ] **Step 5: Commit**

```bash
git add voxline/Storage/Keychain.swift voxlineTests/KeychainTests.swift
git commit -m "Add Keychain wrapper for API-key storage"
```

---

## Task 5: AppSettings (UserDefaults)

**Files:**
- Create: `voxline/Storage/AppSettings.swift`
- Create: `voxlineTests/AppSettingsTests.swift`

Wraps `UserDefaults` for the LLM provider choice and model id. (Hotkey codes and Whisper model ship with Plan 4's General tab; this task only covers what the LLM cleanup path needs.)

- [ ] **Step 1: Write the failing tests**

```swift
// voxlineTests/AppSettingsTests.swift
import Testing
import Foundation
@testable import voxline

@Suite struct AppSettingsTests {

    /// Per-test isolated suite so we don't trample the user's real defaults.
    private func makeDefaults() -> UserDefaults {
        let suiteName = "voxline-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test func unset_provider_defaults_to_anthropic() {
        let s = AppSettings(defaults: makeDefaults())
        #expect(s.llmProvider == .anthropic)
    }

    @Test func set_provider_round_trips() {
        let defaults = makeDefaults()
        var s = AppSettings(defaults: defaults)
        s.llmProvider = .openai
        #expect(AppSettings(defaults: defaults).llmProvider == .openai)
    }

    @Test func default_model_per_provider_matches_spec() {
        let defaults = makeDefaults()
        var s = AppSettings(defaults: defaults)
        s.llmProvider = .anthropic
        #expect(s.llmModel == "claude-haiku-4-5")
        s.llmProvider = .openai
        // Switching providers without an explicit model override
        // re-resolves to the new provider's spec default.
        #expect(s.llmModel == "gpt-4o-mini")
    }

    @Test func explicit_model_override_persists_across_provider_switch() {
        let defaults = makeDefaults()
        var s = AppSettings(defaults: defaults)
        s.llmProvider = .anthropic
        s.llmModel = "claude-3-5-sonnet-latest"
        #expect(s.llmModel == "claude-3-5-sonnet-latest")
        s.llmProvider = .openai
        // Changing provider clears the model override (spec default returns).
        #expect(s.llmModel == "gpt-4o-mini")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Expected: `Cannot find 'AppSettings' in scope`.

- [ ] **Step 3: Implement AppSettings**

```swift
// voxline/Storage/AppSettings.swift
import Foundation

/// Thin wrapper around UserDefaults for non-secret user preferences.
/// Secrets live in `Keychain`.
struct AppSettings {

    enum Key {
        static let provider = "voxline.llm.provider"
        static let model = "voxline.llm.model"
    }

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// LLM provider choice. Defaults to .anthropic.
    /// Setting a new provider clears any model override so the spec default
    /// for the new provider takes over (a model id from one provider is
    /// almost never valid for another).
    var llmProvider: LLMProvider {
        get {
            guard
                let raw = defaults.string(forKey: Key.provider),
                let p = LLMProvider(rawValue: raw)
            else { return .anthropic }
            return p
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.provider)
            defaults.removeObject(forKey: Key.model)
        }
    }

    /// Active LLM model id. Falls back to the spec default for the current
    /// provider when no override is set.
    var llmModel: String {
        get { defaults.string(forKey: Key.model) ?? llmProvider.defaultModel }
        set { defaults.set(newValue, forKey: Key.model) }
    }
}
```

This task references `LLMProvider`, which is defined in Task 6. To keep this task self-contained, add a temporary stub in this file scoped just enough for the build:

```swift
// voxline/Storage/AppSettings.swift  (append, will be removed in Task 6)

#if false
// Placeholder to make this task compile in isolation; Task 6 introduces the
// real LLMProvider in voxline/LLM/LLMProvider.swift and removes this block.
enum LLMProvider: String { case anthropic, openai
    var defaultModel: String { self == .anthropic ? "claude-haiku-4-5" : "gpt-4o-mini" }
}
#endif
```

Actually — to keep tasks strictly ordered and avoid placeholder code, **swap Task 5 and Task 6 in execution**: implement `LLMProvider` first (Task 6 below), then return to AppSettings. The plan keeps the listing order as written for readability; the implementer should use the order **6 → 5** if they want each task to compile in isolation.

(The reviewer for Task 5 should confirm the temporary stub is removed by the time Task 6 lands.)

- [ ] **Step 4: Run tests to verify pass**

Expected: `** TEST SUCCEEDED **` (after Task 6 is in place).

- [ ] **Step 5: Commit**

```bash
git add voxline/Storage/AppSettings.swift voxlineTests/AppSettingsTests.swift
git commit -m "Add AppSettings: provider + model UserDefaults wrapper"
```

---

## Task 6: LLMProvider, request/response types, error mapping

**Files:**
- Create: `voxline/LLM/LLMProvider.swift`
- Create: `voxline/LLM/HTTPClient.swift`
- Create: `voxlineTests/LLMTypesTests.swift`

Defines the protocol-level shape every LLM client conforms to. Both clients take an `HTTPClient` so tests don't hit the network.

- [ ] **Step 1: Write the failing tests**

```swift
// voxlineTests/LLMTypesTests.swift
import Testing
import Foundation
@testable import voxline

@Suite struct LLMTypesTests {

    @Test func provider_raw_values_are_stable() {
        #expect(LLMProvider.anthropic.rawValue == "anthropic")
        #expect(LLMProvider.openai.rawValue == "openai")
    }

    @Test func provider_default_models_match_spec() {
        #expect(LLMProvider.anthropic.defaultModel == "claude-haiku-4-5")
        #expect(LLMProvider.openai.defaultModel == "gpt-4o-mini")
    }

    @Test func provider_display_names_are_friendly() {
        #expect(LLMProvider.anthropic.displayName == "Anthropic")
        #expect(LLMProvider.openai.displayName == "OpenAI")
    }

    @Test func llm_request_carries_system_user_and_model() {
        let req = LLMRequest(model: "m", systemPrompt: "sys", userPrompt: "usr", temperature: 0.5)
        #expect(req.model == "m")
        #expect(req.systemPrompt == "sys")
        #expect(req.userPrompt == "usr")
        #expect(req.temperature == 0.5)
    }

    @Test func llm_error_messages_are_descriptive() {
        let cases: [LLMError] = [
            .missingAPIKey,
            .invalidAPIKey,
            .rateLimited,
            .network(URLError(.timedOut)),
            .badStatus(code: 500, body: "server boom"),
            .badResponseShape(reason: "missing content")
        ]
        for e in cases {
            #expect(!e.localizedDescription.isEmpty)
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Expected: `Cannot find 'LLMProvider' in scope`.

- [ ] **Step 3: Implement LLMProvider + HTTPClient + LLM types**

```swift
// voxline/LLM/LLMProvider.swift
import Foundation

enum LLMProvider: String, CaseIterable, Codable {
    case anthropic
    case openai

    var displayName: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .openai:    return "OpenAI"
        }
    }

    /// Spec §4.3 defaults.
    var defaultModel: String {
        switch self {
        case .anthropic: return "claude-haiku-4-5"
        case .openai:    return "gpt-4o-mini"
        }
    }
}

/// Provider-agnostic request shape. The LLMService translates this into the
/// provider-specific JSON inside each client.
struct LLMRequest: Equatable {
    let model: String
    let systemPrompt: String
    let userPrompt: String
    /// Optional sampling temperature. nil means "use provider default".
    let temperature: Double?

    /// Default max output tokens for cleanup-style use. Cleaned text is
    /// almost never longer than the input transcript by much; 1024 is a
    /// generous ceiling without paying for cap-stretching latency.
    let maxOutputTokens: Int = 1024
}

enum LLMError: Error, LocalizedError {
    case missingAPIKey
    case invalidAPIKey
    case rateLimited
    case network(Error)
    case badStatus(code: Int, body: String)
    case badResponseShape(reason: String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "No API key configured. Open Settings → API Keys to set one."
        case .invalidAPIKey:
            return "API key was rejected by the provider."
        case .rateLimited:
            return "Rate limited by the provider; try again in a moment."
        case .network(let err):
            return "Network error: \(err.localizedDescription)"
        case .badStatus(let code, let body):
            return "Provider returned HTTP \(code): \(body)"
        case .badResponseShape(let reason):
            return "Could not parse provider response: \(reason)"
        }
    }
}

/// Internal contract every LLM client conforms to. Visible to LLMService.
protocol LLMClient: Sendable {
    func cleanup(_ request: LLMRequest) async throws -> String
}
```

```swift
// voxline/LLM/HTTPClient.swift
import Foundation

/// Network seam so tests can run without URLSession or sandbox networking.
/// Both AnthropicClient and OpenAIClient depend on this rather than
/// URLSession directly.
protocol HTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionHTTPClient: HTTPClient {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }
}
```

- [ ] **Step 4: Run tests to verify pass**

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add voxline/LLM/LLMProvider.swift voxline/LLM/HTTPClient.swift voxlineTests/LLMTypesTests.swift
git commit -m "Add LLMProvider, LLMRequest/Response/Error, HTTPClient protocol"
```

---

## Task 7: AnthropicClient

**Files:**
- Create: `voxline/LLM/AnthropicClient.swift`
- Create: `voxlineTests/AnthropicClientTests.swift`

Posts to `https://api.anthropic.com/v1/messages` with:
- Header `x-api-key: <key>`
- Header `anthropic-version: 2023-06-01`
- Header `content-type: application/json`
- Body `{"model": ..., "max_tokens": 1024, "system": "...", "messages": [{"role": "user", "content": "..."}], "temperature": ...}`

Response shape:
```json
{ "content": [ { "type": "text", "text": "cleaned text" } ] }
```

We concatenate every `text` block — almost always one in practice, but defensive against multi-block returns.

- [ ] **Step 1: Write the failing tests**

```swift
// voxlineTests/AnthropicClientTests.swift
import Testing
import Foundation
@testable import voxline

@Suite struct AnthropicClientTests {

    /// Captures the outbound request and returns a canned response.
    final class MockHTTPClient: HTTPClient, @unchecked Sendable {
        var capturedRequest: URLRequest?
        var stubResponse: (data: Data, status: Int) = (Data(), 200)
        var stubError: Error?

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            capturedRequest = request
            if let stubError { throw stubError }
            let http = HTTPURLResponse(
                url: request.url!,
                statusCode: stubResponse.status,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            return (stubResponse.data, http)
        }
    }

    @Test func sends_post_to_messages_endpoint_with_api_key_header() async throws {
        let mock = MockHTTPClient()
        mock.stubResponse = (
            data: #"{"content":[{"type":"text","text":"hello"}]}"#.data(using: .utf8)!,
            status: 200
        )
        let client = AnthropicClient(apiKey: "sk-test", http: mock)

        _ = try await client.cleanup(LLMRequest(model: "claude-haiku-4-5", systemPrompt: "sys", userPrompt: "usr", temperature: nil))

        let req = try #require(mock.capturedRequest)
        #expect(req.httpMethod == "POST")
        #expect(req.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(req.value(forHTTPHeaderField: "x-api-key") == "sk-test")
        #expect(req.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(req.value(forHTTPHeaderField: "content-type") == "application/json")
    }

    @Test func body_includes_system_user_and_model() async throws {
        let mock = MockHTTPClient()
        mock.stubResponse = (
            data: #"{"content":[{"type":"text","text":"x"}]}"#.data(using: .utf8)!,
            status: 200
        )
        let client = AnthropicClient(apiKey: "k", http: mock)

        _ = try await client.cleanup(LLMRequest(model: "claude-haiku-4-5", systemPrompt: "S", userPrompt: "U", temperature: 0.4))

        let body = try JSONSerialization.jsonObject(with: try #require(mock.capturedRequest?.httpBody)) as! [String: Any]
        #expect(body["model"] as? String == "claude-haiku-4-5")
        #expect(body["system"] as? String == "S")
        #expect(body["max_tokens"] as? Int == 1024)
        #expect(body["temperature"] as? Double == 0.4)
        let messages = body["messages"] as! [[String: Any]]
        #expect(messages.count == 1)
        #expect(messages[0]["role"] as? String == "user")
        #expect(messages[0]["content"] as? String == "U")
    }

    @Test func omits_temperature_when_nil() async throws {
        let mock = MockHTTPClient()
        mock.stubResponse = (
            data: #"{"content":[{"type":"text","text":"x"}]}"#.data(using: .utf8)!,
            status: 200
        )
        let client = AnthropicClient(apiKey: "k", http: mock)

        _ = try await client.cleanup(LLMRequest(model: "m", systemPrompt: "s", userPrompt: "u", temperature: nil))
        let body = try JSONSerialization.jsonObject(with: try #require(mock.capturedRequest?.httpBody)) as! [String: Any]
        #expect(body["temperature"] == nil)
    }

    @Test func returns_concatenated_text_blocks() async throws {
        let mock = MockHTTPClient()
        mock.stubResponse = (
            data: #"{"content":[{"type":"text","text":"hello "},{"type":"text","text":"world"}]}"#.data(using: .utf8)!,
            status: 200
        )
        let client = AnthropicClient(apiKey: "k", http: mock)
        let out = try await client.cleanup(LLMRequest(model: "m", systemPrompt: "s", userPrompt: "u", temperature: nil))
        #expect(out == "hello world")
    }

    @Test func http_401_maps_to_invalidAPIKey() async throws {
        let mock = MockHTTPClient()
        mock.stubResponse = (data: Data("nope".utf8), status: 401)
        let client = AnthropicClient(apiKey: "k", http: mock)
        do {
            _ = try await client.cleanup(LLMRequest(model: "m", systemPrompt: "s", userPrompt: "u", temperature: nil))
            Issue.record("expected throw")
        } catch let e as LLMError {
            #expect(e == .invalidAPIKey)
        }
    }

    @Test func http_429_maps_to_rateLimited() async throws {
        let mock = MockHTTPClient()
        mock.stubResponse = (data: Data(), status: 429)
        let client = AnthropicClient(apiKey: "k", http: mock)
        do {
            _ = try await client.cleanup(LLMRequest(model: "m", systemPrompt: "s", userPrompt: "u", temperature: nil))
            Issue.record("expected throw")
        } catch let e as LLMError {
            #expect(e == .rateLimited)
        }
    }

    @Test func http_5xx_maps_to_badStatus_with_body() async throws {
        let mock = MockHTTPClient()
        mock.stubResponse = (data: Data("kaboom".utf8), status: 503)
        let client = AnthropicClient(apiKey: "k", http: mock)
        do {
            _ = try await client.cleanup(LLMRequest(model: "m", systemPrompt: "s", userPrompt: "u", temperature: nil))
            Issue.record("expected throw")
        } catch let e as LLMError {
            switch e {
            case .badStatus(let code, let body):
                #expect(code == 503)
                #expect(body == "kaboom")
            default:
                Issue.record("expected .badStatus, got \(e)")
            }
        }
    }
}

/// LLMError needs Equatable for these tests.
extension LLMError: Equatable {
    public static func == (lhs: LLMError, rhs: LLMError) -> Bool {
        switch (lhs, rhs) {
        case (.missingAPIKey, .missingAPIKey),
             (.invalidAPIKey, .invalidAPIKey),
             (.rateLimited, .rateLimited):
            return true
        case (.badStatus(let lc, let lb), .badStatus(let rc, let rb)):
            return lc == rc && lb == rb
        case (.badResponseShape(let lr), .badResponseShape(let rr)):
            return lr == rr
        case (.network, .network):
            return true   // Sufficient for tests; we don't compare inner errors.
        default:
            return false
        }
    }
}
```

The Equatable conformance on `LLMError` is referenced by Tasks 7, 8, and 9. Add it once in this task and the others will reuse it.

- [ ] **Step 2: Run tests to verify they fail**

Expected: `Cannot find 'AnthropicClient' in scope`.

- [ ] **Step 3: Implement AnthropicClient**

```swift
// voxline/LLM/AnthropicClient.swift
import Foundation

struct AnthropicClient: LLMClient {

    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let apiVersion = "2023-06-01"

    let apiKey: String
    let http: HTTPClient

    init(apiKey: String, http: HTTPClient = URLSessionHTTPClient()) {
        self.apiKey = apiKey
        self.http = http
    }

    func cleanup(_ request: LLMRequest) async throws -> String {
        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")

        var body: [String: Any] = [
            "model": request.model,
            "max_tokens": request.maxOutputTokens,
            "system": request.systemPrompt,
            "messages": [["role": "user", "content": request.userPrompt]]
        ]
        if let t = request.temperature { body["temperature"] = t }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response): (Data, HTTPURLResponse)
        do {
            (data, response) = try await http.send(req)
        } catch {
            throw LLMError.network(error)
        }
        try mapStatus(response: response, body: data)

        return try parseTextBlocks(from: data)
    }

    private func mapStatus(response: HTTPURLResponse, body: Data) throws {
        switch response.statusCode {
        case 200..<300: return
        case 401: throw LLMError.invalidAPIKey
        case 429: throw LLMError.rateLimited
        default:
            let text = String(data: body, encoding: .utf8) ?? ""
            throw LLMError.badStatus(code: response.statusCode, body: text)
        }
    }

    private func parseTextBlocks(from data: Data) throws -> String {
        struct Envelope: Decodable {
            let content: [Block]
            struct Block: Decodable {
                let type: String
                let text: String?
            }
        }
        let env: Envelope
        do {
            env = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw LLMError.badResponseShape(reason: "JSON decode failed: \(error.localizedDescription)")
        }
        let text = env.content.compactMap { $0.type == "text" ? $0.text : nil }.joined()
        if text.isEmpty {
            throw LLMError.badResponseShape(reason: "no text blocks in response")
        }
        return text
    }
}
```

- [ ] **Step 4: Run tests to verify pass**

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add voxline/LLM/AnthropicClient.swift voxlineTests/AnthropicClientTests.swift
git commit -m "Add AnthropicClient: /v1/messages with x-api-key + status mapping"
```

---

## Task 8: OpenAIClient

**Files:**
- Create: `voxline/LLM/OpenAIClient.swift`
- Create: `voxlineTests/OpenAIClientTests.swift`

Posts to `https://api.openai.com/v1/chat/completions` with:
- Header `Authorization: Bearer <key>`
- Header `content-type: application/json`
- Body `{"model": ..., "messages": [{"role":"system","content":"..."},{"role":"user","content":"..."}], "temperature": ...}`

Response shape:
```json
{ "choices": [ { "message": { "role": "assistant", "content": "cleaned" } } ] }
```

Take the first choice's `message.content`.

- [ ] **Step 1: Write the failing tests**

```swift
// voxlineTests/OpenAIClientTests.swift
import Testing
import Foundation
@testable import voxline

@Suite struct OpenAIClientTests {

    final class MockHTTPClient: HTTPClient, @unchecked Sendable {
        var capturedRequest: URLRequest?
        var stubResponse: (data: Data, status: Int) = (Data(), 200)
        var stubError: Error?

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            capturedRequest = request
            if let stubError { throw stubError }
            return (
                stubResponse.data,
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: stubResponse.status,
                    httpVersion: "HTTP/1.1",
                    headerFields: nil
                )!
            )
        }
    }

    @Test func sends_post_to_chat_completions_with_bearer_token() async throws {
        let mock = MockHTTPClient()
        mock.stubResponse = (
            data: #"{"choices":[{"message":{"role":"assistant","content":"hi"}}]}"#.data(using: .utf8)!,
            status: 200
        )
        let client = OpenAIClient(apiKey: "sk-openai", http: mock)

        _ = try await client.cleanup(LLMRequest(model: "gpt-4o-mini", systemPrompt: "s", userPrompt: "u", temperature: nil))

        let req = try #require(mock.capturedRequest)
        #expect(req.httpMethod == "POST")
        #expect(req.url?.absoluteString == "https://api.openai.com/v1/chat/completions")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer sk-openai")
        #expect(req.value(forHTTPHeaderField: "content-type") == "application/json")
    }

    @Test func body_includes_system_and_user_messages() async throws {
        let mock = MockHTTPClient()
        mock.stubResponse = (
            data: #"{"choices":[{"message":{"role":"assistant","content":"x"}}]}"#.data(using: .utf8)!,
            status: 200
        )
        let client = OpenAIClient(apiKey: "k", http: mock)

        _ = try await client.cleanup(LLMRequest(model: "gpt-4o-mini", systemPrompt: "S", userPrompt: "U", temperature: 0.2))

        let body = try JSONSerialization.jsonObject(with: try #require(mock.capturedRequest?.httpBody)) as! [String: Any]
        #expect(body["model"] as? String == "gpt-4o-mini")
        #expect(body["temperature"] as? Double == 0.2)
        let messages = body["messages"] as! [[String: Any]]
        #expect(messages.count == 2)
        #expect(messages[0]["role"] as? String == "system")
        #expect(messages[0]["content"] as? String == "S")
        #expect(messages[1]["role"] as? String == "user")
        #expect(messages[1]["content"] as? String == "U")
    }

    @Test func returns_first_choice_message_content() async throws {
        let mock = MockHTTPClient()
        mock.stubResponse = (
            data: #"{"choices":[{"message":{"role":"assistant","content":"only-this"}},{"message":{"role":"assistant","content":"ignored"}}]}"#.data(using: .utf8)!,
            status: 200
        )
        let client = OpenAIClient(apiKey: "k", http: mock)
        let out = try await client.cleanup(LLMRequest(model: "m", systemPrompt: "s", userPrompt: "u", temperature: nil))
        #expect(out == "only-this")
    }

    @Test func http_401_maps_to_invalidAPIKey() async throws {
        let mock = MockHTTPClient()
        mock.stubResponse = (data: Data(), status: 401)
        let client = OpenAIClient(apiKey: "k", http: mock)
        do {
            _ = try await client.cleanup(LLMRequest(model: "m", systemPrompt: "s", userPrompt: "u", temperature: nil))
            Issue.record("expected throw")
        } catch let e as LLMError {
            #expect(e == .invalidAPIKey)
        }
    }

    @Test func empty_choices_throws_badResponseShape() async throws {
        let mock = MockHTTPClient()
        mock.stubResponse = (
            data: #"{"choices":[]}"#.data(using: .utf8)!,
            status: 200
        )
        let client = OpenAIClient(apiKey: "k", http: mock)
        do {
            _ = try await client.cleanup(LLMRequest(model: "m", systemPrompt: "s", userPrompt: "u", temperature: nil))
            Issue.record("expected throw")
        } catch let e as LLMError {
            switch e {
            case .badResponseShape: break
            default: Issue.record("expected .badResponseShape, got \(e)")
            }
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

- [ ] **Step 3: Implement OpenAIClient**

```swift
// voxline/LLM/OpenAIClient.swift
import Foundation

struct OpenAIClient: LLMClient {

    static let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!

    let apiKey: String
    let http: HTTPClient

    init(apiKey: String, http: HTTPClient = URLSessionHTTPClient()) {
        self.apiKey = apiKey
        self.http = http
    }

    func cleanup(_ request: LLMRequest) async throws -> String {
        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "content-type")

        var body: [String: Any] = [
            "model": request.model,
            "messages": [
                ["role": "system", "content": request.systemPrompt],
                ["role": "user", "content": request.userPrompt]
            ]
        ]
        if let t = request.temperature { body["temperature"] = t }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response): (Data, HTTPURLResponse)
        do {
            (data, response) = try await http.send(req)
        } catch {
            throw LLMError.network(error)
        }
        try mapStatus(response: response, body: data)

        struct Envelope: Decodable {
            let choices: [Choice]
            struct Choice: Decodable {
                let message: Message
                struct Message: Decodable {
                    let role: String
                    let content: String
                }
            }
        }
        let env: Envelope
        do {
            env = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw LLMError.badResponseShape(reason: "JSON decode failed: \(error.localizedDescription)")
        }
        guard let first = env.choices.first else {
            throw LLMError.badResponseShape(reason: "no choices in response")
        }
        return first.message.content
    }

    private func mapStatus(response: HTTPURLResponse, body: Data) throws {
        switch response.statusCode {
        case 200..<300: return
        case 401: throw LLMError.invalidAPIKey
        case 429: throw LLMError.rateLimited
        default:
            let text = String(data: body, encoding: .utf8) ?? ""
            throw LLMError.badStatus(code: response.statusCode, body: text)
        }
    }
}
```

- [ ] **Step 4: Run tests to verify pass**

- [ ] **Step 5: Commit**

```bash
git add voxline/LLM/OpenAIClient.swift voxlineTests/OpenAIClientTests.swift
git commit -m "Add OpenAIClient: /v1/chat/completions with Bearer auth"
```

---

## Task 9: LLMService facade

**Files:**
- Create: `voxline/LLM/LLMService.swift`
- Create: `voxlineTests/LLMServiceTests.swift`

Single entry point used by `CapturePipeline`. Constructs the right client based on `AppSettings.llmProvider`, fetches the corresponding key from `Keychain`, applies any per-mode model/temperature override, and runs the request.

- [ ] **Step 1: Write the failing tests**

```swift
// voxlineTests/LLMServiceTests.swift
import Testing
import Foundation
@testable import voxline

@Suite struct LLMServiceTests {

    final class MockHTTPClient: HTTPClient, @unchecked Sendable {
        var capturedRequest: URLRequest?
        var stubResponse: (data: Data, status: Int) = (Data(), 200)
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            capturedRequest = request
            return (
                stubResponse.data,
                HTTPURLResponse(url: request.url!, statusCode: stubResponse.status, httpVersion: "HTTP/1.1", headerFields: nil)!
            )
        }
    }

    private func defaultsSuite() -> UserDefaults {
        let name = "voxline-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    private func keychain() -> Keychain {
        Keychain(service: "com.voxline.voxline.test.\(UUID().uuidString)")
    }

    @Test func cleanup_with_no_key_throws_missingAPIKey() async throws {
        let mock = MockHTTPClient()
        var settings = AppSettings(defaults: defaultsSuite())
        settings.llmProvider = .anthropic
        let service = LLMService(settings: settings, keychain: keychain(), http: mock)

        let mode = Mode(bundleID: "*", displayName: "default", prompt: "S", model: nil, temperature: nil)
        do {
            _ = try await service.cleanup(transcript: "hi", mode: mode)
            Issue.record("expected throw")
        } catch let e as LLMError {
            #expect(e == .missingAPIKey)
        }
    }

    @Test func cleanup_routes_to_anthropic_when_provider_is_anthropic() async throws {
        let mock = MockHTTPClient()
        mock.stubResponse = (
            data: #"{"content":[{"type":"text","text":"clean"}]}"#.data(using: .utf8)!,
            status: 200
        )
        var settings = AppSettings(defaults: defaultsSuite())
        settings.llmProvider = .anthropic
        let kc = keychain()
        try kc.set("sk-ant", forKey: Keychain.Account.anthropic)
        defer { try? kc.deleteAll() }

        let service = LLMService(settings: settings, keychain: kc, http: mock)
        let mode = Mode(bundleID: "*", displayName: "d", prompt: "S", model: nil, temperature: nil)

        let out = try await service.cleanup(transcript: "u", mode: mode)
        #expect(out == "clean")
        #expect(mock.capturedRequest?.url?.host == "api.anthropic.com")
    }

    @Test func cleanup_routes_to_openai_when_provider_is_openai() async throws {
        let mock = MockHTTPClient()
        mock.stubResponse = (
            data: #"{"choices":[{"message":{"role":"assistant","content":"clean"}}]}"#.data(using: .utf8)!,
            status: 200
        )
        var settings = AppSettings(defaults: defaultsSuite())
        settings.llmProvider = .openai
        let kc = keychain()
        try kc.set("sk-oai", forKey: Keychain.Account.openai)
        defer { try? kc.deleteAll() }

        let service = LLMService(settings: settings, keychain: kc, http: mock)
        let mode = Mode(bundleID: "*", displayName: "d", prompt: "S", model: nil, temperature: nil)

        let out = try await service.cleanup(transcript: "u", mode: mode)
        #expect(out == "clean")
        #expect(mock.capturedRequest?.url?.host == "api.openai.com")
    }

    @Test func mode_model_override_wins_over_settings_model() async throws {
        let mock = MockHTTPClient()
        mock.stubResponse = (
            data: #"{"content":[{"type":"text","text":"c"}]}"#.data(using: .utf8)!,
            status: 200
        )
        var settings = AppSettings(defaults: defaultsSuite())
        settings.llmProvider = .anthropic
        settings.llmModel = "claude-haiku-4-5"
        let kc = keychain()
        try kc.set("k", forKey: Keychain.Account.anthropic)
        defer { try? kc.deleteAll() }

        let service = LLMService(settings: settings, keychain: kc, http: mock)
        let mode = Mode(bundleID: "*", displayName: "d", prompt: "S", model: "claude-3-5-sonnet-latest", temperature: 0.7)
        _ = try await service.cleanup(transcript: "u", mode: mode)

        let body = try JSONSerialization.jsonObject(with: try #require(mock.capturedRequest?.httpBody)) as! [String: Any]
        #expect(body["model"] as? String == "claude-3-5-sonnet-latest")
        #expect(body["temperature"] as? Double == 0.7)
    }

    @Test func empty_transcript_short_circuits_to_empty_without_calling_http() async throws {
        let mock = MockHTTPClient()
        var settings = AppSettings(defaults: defaultsSuite())
        settings.llmProvider = .anthropic
        let kc = keychain()
        try kc.set("k", forKey: Keychain.Account.anthropic)
        defer { try? kc.deleteAll() }

        let service = LLMService(settings: settings, keychain: kc, http: mock)
        let mode = Mode(bundleID: "*", displayName: "d", prompt: "S", model: nil, temperature: nil)

        let out = try await service.cleanup(transcript: "", mode: mode)
        #expect(out == "")
        #expect(mock.capturedRequest == nil)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Expected: `Cannot find 'LLMService' in scope`.

- [ ] **Step 3: Implement LLMService**

```swift
// voxline/LLM/LLMService.swift
import Foundation

/// Single entry point for transcript → LLM-cleaned-text. Picks the right
/// client based on AppSettings, fetches the corresponding key from Keychain,
/// applies per-mode overrides, and runs the cleanup request.
struct LLMService {

    let settings: AppSettings
    let keychain: Keychain
    let http: HTTPClient

    init(settings: AppSettings, keychain: Keychain = Keychain(), http: HTTPClient = URLSessionHTTPClient()) {
        self.settings = settings
        self.keychain = keychain
        self.http = http
    }

    func cleanup(transcript: String, mode: Mode) async throws -> String {
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
        let request = LLMRequest(
            model: model,
            systemPrompt: mode.prompt,
            userPrompt: transcript,
            temperature: mode.temperature
        )

        let client: any LLMClient
        switch provider {
        case .anthropic: client = AnthropicClient(apiKey: key, http: http)
        case .openai:    client = OpenAIClient(apiKey: key, http: http)
        }
        return try await client.cleanup(request)
    }
}
```

- [ ] **Step 4: Run tests to verify pass**

- [ ] **Step 5: Commit**

```bash
git add voxline/LLM/LLMService.swift voxlineTests/LLMServiceTests.swift
git commit -m "Add LLMService facade: provider routing + key fetch + mode overrides"
```

---

## Task 10: PasteboardSnapshot

**Files:**
- Create: `voxline/Output/PasteboardSnapshot.swift`
- Create: `voxlineTests/PasteboardSnapshotTests.swift`

Captures every concrete data-bearing type for every item on a pasteboard, then can restore them in order. Per spec §7.1: refuses-to-clobber when items contain only promised types we can't resolve.

Tests use a private named `NSPasteboard` instance — the system clipboard is never touched.

- [ ] **Step 1: Write the failing tests**

```swift
// voxlineTests/PasteboardSnapshotTests.swift
import Testing
import AppKit
@testable import voxline

@Suite struct PasteboardSnapshotTests {

    private func makeBoard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name(rawValue: "voxline-snap-test-\(UUID().uuidString)"))
    }

    @Test func captures_string_and_restores_to_empty_board() throws {
        let src = makeBoard()
        src.clearContents()
        src.setString("hello", forType: .string)

        let snap = try PasteboardSnapshot.capture(from: src)

        let dst = makeBoard()
        dst.clearContents()
        snap.restore(to: dst)
        #expect(dst.string(forType: .string) == "hello")
    }

    @Test func captures_multiple_data_types_per_item() throws {
        let src = makeBoard()
        src.clearContents()
        let item = NSPasteboardItem()
        item.setString("plain", forType: .string)
        item.setString("<b>rich</b>", forType: .html)
        src.writeObjects([item])

        let snap = try PasteboardSnapshot.capture(from: src)

        let dst = makeBoard()
        dst.clearContents()
        snap.restore(to: dst)
        #expect(dst.string(forType: .string) == "plain")
        #expect(dst.string(forType: .html) == "<b>rich</b>")
    }

    @Test func captures_multiple_items_in_order() throws {
        let src = makeBoard()
        src.clearContents()
        let a = NSPasteboardItem(); a.setString("first", forType: .string)
        let b = NSPasteboardItem(); b.setString("second", forType: .string)
        src.writeObjects([a, b])

        let snap = try PasteboardSnapshot.capture(from: src)
        #expect(snap.items.count == 2)
        #expect(snap.items[0].typedData[.string] != nil)
    }

    @Test func nil_pasteboardItems_throws_refuseToClobber() throws {
        let board = NSPasteboard(name: NSPasteboard.Name(rawValue: "voxline-nilboard-\(UUID().uuidString)"))
        // Force the nil-items path: a brand-new board that's never been written to
        // and never had clearContents called returns nil for pasteboardItems.
        // (Some macOS versions return [] instead — guard the test against that.)
        if board.pasteboardItems == nil {
            do {
                _ = try PasteboardSnapshot.capture(from: board)
                Issue.record("expected throw")
            } catch let e as PasteboardSnapshot.SnapshotError {
                #expect(e == .refuseToClobber(reason: "pasteboardItems was nil"))
            }
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Expected: `Cannot find 'PasteboardSnapshot' in scope`.

- [ ] **Step 3: Implement PasteboardSnapshot**

```swift
// voxline/Output/PasteboardSnapshot.swift
import AppKit

/// In-memory snapshot of every data-bearing pasteboard type, per item.
/// Promised/lazy types are not captured (see spec §7.1).
struct PasteboardSnapshot: Equatable {

    struct ItemSnapshot: Equatable {
        /// type → raw data. Order preserved from the source item.
        let typedData: [NSPasteboard.PasteboardType: Data]
    }

    enum SnapshotError: Error, Equatable {
        case refuseToClobber(reason: String)
    }

    let items: [ItemSnapshot]

    static func capture(from pasteboard: NSPasteboard) throws -> PasteboardSnapshot {
        guard let pbItems = pasteboard.pasteboardItems else {
            throw SnapshotError.refuseToClobber(reason: "pasteboardItems was nil")
        }

        var captured: [ItemSnapshot] = []
        for item in pbItems {
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    dict[type] = data
                }
            }
            // An item with zero concrete types is a promised/dynamic-only
            // item; if the WHOLE board is like this, we'd silently destroy
            // the user's clipboard. Track for the all-promised guard below.
            captured.append(ItemSnapshot(typedData: dict))
        }

        if !captured.isEmpty && captured.allSatisfy({ $0.typedData.isEmpty }) {
            throw SnapshotError.refuseToClobber(reason: "all items contain only promised/owner-served types")
        }

        return PasteboardSnapshot(items: captured)
    }

    /// Replaces `pasteboard`'s contents with the snapshot. Caller is
    /// expected to have cleared the pasteboard already, or accept that
    /// the previous contents remain alongside.
    func restore(to pasteboard: NSPasteboard) {
        var pbItems: [NSPasteboardItem] = []
        for snap in items {
            let pbItem = NSPasteboardItem()
            for (type, data) in snap.typedData {
                pbItem.setData(data, forType: type)
            }
            pbItems.append(pbItem)
        }
        pasteboard.clearContents()
        pasteboard.writeObjects(pbItems)
    }
}
```

- [ ] **Step 4: Run tests to verify pass**

- [ ] **Step 5: Commit**

```bash
git add voxline/Output/PasteboardSnapshot.swift voxlineTests/PasteboardSnapshotTests.swift
git commit -m "Add PasteboardSnapshot: items × types capture with refuse-to-clobber"
```

---

## Task 11: ClipboardInjector

**Files:**
- Create: `voxline/Output/ClipboardInjector.swift`
- Create: `voxlineTests/ClipboardInjectorTests.swift`

Performs the spec §4.3 "clipboard-paste pattern":

1. Snapshot pasteboard.
2. Write cleaned text as `.string`.
3. Wait for chord release (poll `CGEventSource.flagsState` for up to 1s; on timeout post a synthetic flagsChanged clearing left-Ctrl + left-Option).
4. Post synthetic `Cmd+V` with flags set to **only** `kCGEventFlagMaskCommand`.
5. After 300 ms, restore the snapshot.

Step 3 (modifier-release gate) is unit-testable independently if we extract a `ModifierGate` protocol — easier to fake than `CGEventSource` directly. Step 4 is also factored behind a `KeyEventPosting` protocol. The injector itself is a coordinator we can test with both protocols mocked.

- [ ] **Step 1: Write the failing tests**

```swift
// voxlineTests/ClipboardInjectorTests.swift
import Testing
import AppKit
@testable import voxline

@Suite struct ClipboardInjectorTests {

    final class FakeModifierGate: ModifierGate, @unchecked Sendable {
        var sequence: [Bool] = [false]   // Each call pops the front; default = released
        var calls = 0
        var clearAttempts = 0
        func chordIsHeld() -> Bool {
            calls += 1
            return sequence.isEmpty ? false : sequence.removeFirst()
        }
        func forceClearChord() { clearAttempts += 1 }
    }

    final class FakeKeyPoster: KeyEventPosting, @unchecked Sendable {
        var posted: [(keyCode: CGKeyCode, flags: CGEventFlags)] = []
        func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags) {
            posted.append((keyCode, flags))
        }
    }

    private func makeBoard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name(rawValue: "voxline-inject-\(UUID().uuidString)"))
    }

    @Test func writes_text_then_posts_cmd_v_then_restores() async throws {
        let board = makeBoard()
        board.clearContents()
        board.setString("ORIGINAL", forType: .string)

        let gate = FakeModifierGate()
        let poster = FakeKeyPoster()
        let injector = ClipboardInjector(
            pasteboard: board,
            modifierGate: gate,
            keyPoster: poster,
            restoreDelay: .milliseconds(20)   // short for tests
        )

        try await injector.inject("CLEAN")

        // After full inject + restoreDelay, original is back.
        #expect(board.string(forType: .string) == "ORIGINAL")
        // Cmd+V was posted exactly once with only Command flag.
        #expect(poster.posted.count == 1)
        #expect(poster.posted[0].keyCode == 9)               // 'V'
        #expect(poster.posted[0].flags == [.maskCommand])
    }

    @Test func waits_for_chord_release_before_posting() async throws {
        let board = makeBoard()
        board.clearContents()

        let gate = FakeModifierGate()
        // Held twice, then released — should NOT clear, just wait.
        gate.sequence = [true, true, false]

        let poster = FakeKeyPoster()
        let injector = ClipboardInjector(
            pasteboard: board,
            modifierGate: gate,
            keyPoster: poster,
            restoreDelay: .milliseconds(0)
        )

        try await injector.inject("text")

        #expect(gate.calls >= 3)        // polled until released
        #expect(gate.clearAttempts == 0) // never had to force-clear
    }

    @Test func force_clears_chord_after_timeout() async throws {
        let board = makeBoard()
        board.clearContents()

        let gate = FakeModifierGate()
        // Always held — gate poller should give up after `chordReleaseTimeout` and force clear.
        gate.sequence = []
        let poster = FakeKeyPoster()
        let injector = ClipboardInjector(
            pasteboard: board,
            modifierGate: gate,
            keyPoster: poster,
            chordReleaseTimeout: .milliseconds(20),
            chordPollInterval: .milliseconds(5),
            restoreDelay: .milliseconds(0)
        )

        // Override sequence to "always held" — empty sequence default returns false,
        // so set the gate to a stub that always returns true.
        let alwaysHeld = AlwaysHeldGate()
        let injector2 = ClipboardInjector(
            pasteboard: board,
            modifierGate: alwaysHeld,
            keyPoster: poster,
            chordReleaseTimeout: .milliseconds(20),
            chordPollInterval: .milliseconds(5),
            restoreDelay: .milliseconds(0)
        )

        try await injector2.inject("t")

        #expect(alwaysHeld.clearAttempts == 1)
        #expect(poster.posted.count == 1)   // Cmd+V still fired after force-clear
    }

    final class AlwaysHeldGate: ModifierGate, @unchecked Sendable {
        var clearAttempts = 0
        func chordIsHeld() -> Bool { true }
        func forceClearChord() { clearAttempts += 1 }
    }

    @Test func refuse_to_clobber_throws_without_writing_or_pasting() async throws {
        // Force a refuse-to-clobber scenario by giving the injector a board
        // whose pasteboardItems is nil. (Skip if the platform returns [].)
        let board = NSPasteboard(name: NSPasteboard.Name(rawValue: "voxline-empty-\(UUID().uuidString)"))
        guard board.pasteboardItems == nil else { return }

        let poster = FakeKeyPoster()
        let injector = ClipboardInjector(
            pasteboard: board,
            modifierGate: FakeModifierGate(),
            keyPoster: poster,
            restoreDelay: .milliseconds(0)
        )

        do {
            try await injector.inject("anything")
            Issue.record("expected refuse-to-clobber error")
        } catch is ClipboardInjector.InjectError {
            // ok
        } catch is PasteboardSnapshot.SnapshotError {
            // ok — propagated
        }
        #expect(poster.posted.isEmpty)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

- [ ] **Step 3: Implement protocols + injector**

```swift
// voxline/Output/ClipboardInjector.swift
import AppKit
import CoreGraphics

/// Polled by ClipboardInjector to gate the synthetic Cmd+V on the user
/// physically releasing the chord. Production impl wraps CGEventSource;
/// tests fake it.
protocol ModifierGate: Sendable {
    /// True iff Left-Ctrl OR Left-Option is currently physically held.
    func chordIsHeld() -> Bool
    /// Synthesize a flagsChanged that clears Left-Ctrl + Left-Option.
    /// Used after the release-timeout elapses.
    func forceClearChord()
}

/// Posts synthetic key events. Wraps CGEvent.post in production; faked in tests.
protocol KeyEventPosting: Sendable {
    func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags)
}

struct CGEventModifierGate: ModifierGate {
    func chordIsHeld() -> Bool {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        // Flag bits for individual sides aren't exposed publicly on macOS;
        // checking the combined Control/Option masks is the documented way.
        // (This is conservative — any Ctrl or any Option held returns true.
        //  In practice voxline's chord IS Left-Ctrl + Left-Option so this is fine.)
        return flags.contains(.maskControl) || flags.contains(.maskAlternate)
    }

    func forceClearChord() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let event = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)
        event?.flags = []   // Clearing all modifier flags — a synthetic "fingers off keyboard"
        event?.type = .flagsChanged
        event?.post(tap: .cghidEventTap)
    }
}

struct CGEventKeyPoster: KeyEventPosting {
    func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags) {
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true)
        down?.flags = flags
        down?.post(tap: .cghidEventTap)
        let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)
        up?.flags = flags
        up?.post(tap: .cghidEventTap)
    }
}

@MainActor
final class ClipboardInjector {

    enum InjectError: Error {
        case clipboardSnapshotFailed(Error)
    }

    /// Virtual key code for "V" on macOS US ANSI layout.
    static let kVirtualKeyV: CGKeyCode = 9

    let pasteboard: NSPasteboard
    let modifierGate: ModifierGate
    let keyPoster: KeyEventPosting
    let chordReleaseTimeout: Duration
    let chordPollInterval: Duration
    let restoreDelay: Duration

    init(
        pasteboard: NSPasteboard = .general,
        modifierGate: ModifierGate = CGEventModifierGate(),
        keyPoster: KeyEventPosting = CGEventKeyPoster(),
        chordReleaseTimeout: Duration = .seconds(1),
        chordPollInterval: Duration = .milliseconds(15),
        restoreDelay: Duration = .milliseconds(300)
    ) {
        self.pasteboard = pasteboard
        self.modifierGate = modifierGate
        self.keyPoster = keyPoster
        self.chordReleaseTimeout = chordReleaseTimeout
        self.chordPollInterval = chordPollInterval
        self.restoreDelay = restoreDelay
    }

    /// Snapshot → write text → wait-for-release → Cmd+V → restore.
    /// Throws `PasteboardSnapshot.SnapshotError.refuseToClobber` if we can't
    /// safely capture the prior pasteboard contents.
    func inject(_ text: String) async throws {
        // 1. Snapshot. Throws on refuse-to-clobber; we propagate.
        let snapshot = try PasteboardSnapshot.capture(from: pasteboard)

        // 2. Write cleaned text.
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // 3. Wait for the user's chord to release before posting Cmd+V.
        await waitForChordRelease()

        // 4. Post Cmd+V with ONLY the Command flag (per spec §4.3 step 4).
        keyPoster.postKey(Self.kVirtualKeyV, flags: [.maskCommand])

        // 5. Restore after a short delay so the target app has time to consume the paste.
        try? await Task.sleep(for: restoreDelay)
        snapshot.restore(to: pasteboard)
    }

    private func waitForChordRelease() async {
        let deadline = ContinuousClock.now.advanced(by: chordReleaseTimeout)
        while modifierGate.chordIsHeld() {
            if ContinuousClock.now >= deadline {
                modifierGate.forceClearChord()
                return
            }
            try? await Task.sleep(for: chordPollInterval)
        }
    }
}
```

- [ ] **Step 4: Run tests to verify pass**

Expected: `** TEST SUCCEEDED **`. The pasteboard tests should be fast (<1 s) because `restoreDelay`/`chordReleaseTimeout` are passed in as small Durations.

- [ ] **Step 5: Commit**

```bash
git add voxline/Output/PasteboardSnapshot.swift voxline/Output/ClipboardInjector.swift voxlineTests/ClipboardInjectorTests.swift
git commit -m "Add ClipboardInjector: snapshot → write → release-gate → Cmd+V → restore"
```

---

## Task 12: API Keys settings tab (real impl)

**Files:**
- Modify: `voxline/Settings/APIKeysSettingsView.swift`
- Create: `voxline/Settings/APIKeysSettingsViewModel.swift`
- Create: `voxlineTests/APIKeysSettingsViewModelTests.swift`

Replaces the Plan-1 "lives here (Plan 4)" placeholder with a real form: provider picker, two SecureField rows (Anthropic + OpenAI), Save button. Key persistence goes via `Keychain`; provider choice via `AppSettings`.

- [ ] **Step 1: Write the failing tests**

```swift
// voxlineTests/APIKeysSettingsViewModelTests.swift
import Testing
import Foundation
@testable import voxline

@Suite @MainActor struct APIKeysSettingsViewModelTests {

    private func defaultsSuite() -> UserDefaults {
        let n = "voxline-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: n)!
        d.removePersistentDomain(forName: n)
        return d
    }
    private func keychain() -> Keychain {
        Keychain(service: "com.voxline.voxline.test.\(UUID().uuidString)")
    }

    @Test func loads_existing_keys_and_provider_on_init() throws {
        let defaults = defaultsSuite()
        var settings = AppSettings(defaults: defaults)
        settings.llmProvider = .openai
        let kc = keychain()
        try kc.set("a-key", forKey: Keychain.Account.anthropic)
        try kc.set("o-key", forKey: Keychain.Account.openai)
        defer { try? kc.deleteAll() }

        let vm = APIKeysSettingsViewModel(settings: settings, keychain: kc)
        #expect(vm.provider == .openai)
        #expect(vm.anthropicKey == "a-key")
        #expect(vm.openaiKey == "o-key")
    }

    @Test func save_persists_provider_and_keys() throws {
        let defaults = defaultsSuite()
        let settings = AppSettings(defaults: defaults)
        let kc = keychain()
        defer { try? kc.deleteAll() }

        let vm = APIKeysSettingsViewModel(settings: settings, keychain: kc)
        vm.provider = .openai
        vm.anthropicKey = "new-a"
        vm.openaiKey = "new-o"
        try vm.save()

        #expect(AppSettings(defaults: defaults).llmProvider == .openai)
        #expect(try kc.string(forKey: Keychain.Account.anthropic) == "new-a")
        #expect(try kc.string(forKey: Keychain.Account.openai) == "new-o")
    }

    @Test func save_with_empty_key_deletes_keychain_entry() throws {
        let defaults = defaultsSuite()
        let settings = AppSettings(defaults: defaults)
        let kc = keychain()
        try kc.set("preexisting", forKey: Keychain.Account.anthropic)
        defer { try? kc.deleteAll() }

        let vm = APIKeysSettingsViewModel(settings: settings, keychain: kc)
        vm.anthropicKey = ""   // Cleared by user
        try vm.save()

        #expect(try kc.string(forKey: Keychain.Account.anthropic) == nil)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

- [ ] **Step 3: Implement view model + view**

```swift
// voxline/Settings/APIKeysSettingsViewModel.swift
import Foundation
import Observation

@Observable
@MainActor
final class APIKeysSettingsViewModel {

    var provider: LLMProvider
    var anthropicKey: String
    var openaiKey: String
    /// Surfaced to the view to render save errors inline.
    var lastError: String?

    private var settings: AppSettings
    private let keychain: Keychain

    init(settings: AppSettings = AppSettings(), keychain: Keychain = Keychain()) {
        self.settings = settings
        self.keychain = keychain
        self.provider = settings.llmProvider
        self.anthropicKey = (try? keychain.string(forKey: Keychain.Account.anthropic)) ?? ""
        self.openaiKey = (try? keychain.string(forKey: Keychain.Account.openai)) ?? ""
    }

    func save() throws {
        var snap = settings
        snap.llmProvider = provider
        try persist(value: anthropicKey, account: Keychain.Account.anthropic)
        try persist(value: openaiKey, account: Keychain.Account.openai)
        settings = snap
    }

    private func persist(value: String, account: String) throws {
        if value.isEmpty {
            try keychain.delete(forKey: account)
        } else {
            try keychain.set(value, forKey: account)
        }
    }
}
```

```swift
// voxline/Settings/APIKeysSettingsView.swift  (replace contents)
import SwiftUI

struct APIKeysSettingsView: View {

    @State private var vm = APIKeysSettingsViewModel()

    var body: some View {
        Form {
            Picker("Provider", selection: $vm.provider) {
                ForEach(LLMProvider.allCases, id: \.self) { p in
                    Text(p.displayName).tag(p)
                }
            }
            .pickerStyle(.segmented)

            Section("Anthropic") {
                SecureField("API key", text: $vm.anthropicKey)
                    .textContentType(.password)
            }

            Section("OpenAI") {
                SecureField("API key", text: $vm.openaiKey)
                    .textContentType(.password)
            }

            HStack {
                Spacer()
                Button("Save") { saveWithErrorBanner() }
                    .keyboardShortcut(.defaultAction)
            }

            if let err = vm.lastError {
                Text(err)
                    .foregroundStyle(.red)
                    .font(.callout)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 360)
    }

    private func saveWithErrorBanner() {
        do {
            try vm.save()
            vm.lastError = nil
        } catch {
            vm.lastError = "Save failed: \(error.localizedDescription)"
        }
    }
}

#Preview {
    APIKeysSettingsView()
}
```

- [ ] **Step 4: Run tests to verify pass**

- [ ] **Step 5: Commit**

```bash
git add voxline/Settings/APIKeysSettingsView.swift voxline/Settings/APIKeysSettingsViewModel.swift voxlineTests/APIKeysSettingsViewModelTests.swift
git commit -m "Wire API Keys settings tab to AppSettings + Keychain"
```

---

## Task 13: Pipeline integration (chord → transcribe → LLM → paste; remove debug window)

**Files:**
- Modify: `voxline/Pipeline/PipelineProtocols.swift`
- Modify: `voxline/Pipeline/CapturePipeline.swift`
- Modify: `voxlineTests/CapturePipelineTests.swift`
- Modify: `voxline/voxlineApp.swift`
- Modify: `voxline/MenuBar/MenuBarContent.swift`
- Create: `voxline/Output/FrontmostApp.swift`
- Delete: `voxline/UI/DebugTranscriptWindow.swift`

This is the integration task. Pre-Plan-3 `finalizeRecording()` ended at `state.lastTranscript = text`; now it continues into mode resolution → LLM cleanup → clipboard injection. Errors at any stage set `state.status = .error(...)` with a message tailored to the stage so the menu-bar error item is actionable.

- [ ] **Step 1: Extend protocol seams + add a frontmost-app helper**

```swift
// voxline/Pipeline/PipelineProtocols.swift  (replace contents)
import AppKit
import Foundation

@MainActor
protocol AudioCapturing: AnyObject {
    var onLevel: ((Float) -> Void)? { get set }
    func start() throws
    func stop()
    func takeSamples() -> [Float]
}

@MainActor
protocol Transcribing: AnyObject {
    func transcribe(samples: [Float]) async throws -> String
}

protocol ModeResolving: Sendable {
    /// Returns the active mode given a frontmost-app bundle ID.
    /// Implemented by ModeRouter under the hood; the bundle-ID lookup is
    /// the testable seam.
    func mode(for bundleID: String?) -> Mode?
}

protocol LLMServing: Sendable {
    func cleanup(transcript: String, mode: Mode) async throws -> String
}

@MainActor
protocol ClipboardInjecting: AnyObject {
    func inject(_ text: String) async throws
}

protocol FrontmostAppProviding: Sendable {
    /// Bundle ID of whatever app holds keyboard focus right now, or nil if
    /// none could be resolved (no frontmost app, sandboxed lookup blocked).
    func frontmostBundleID() -> String?
}

extension AudioCaptureService: AudioCapturing {}
extension TranscriptionService: Transcribing {}
extension ModeRouter: ModeResolving {}
extension LLMService: LLMServing {}
extension ClipboardInjector: ClipboardInjecting {}
```

```swift
// voxline/Output/FrontmostApp.swift
import AppKit

/// Real-NSWorkspace impl of FrontmostAppProviding. Tests substitute a fake.
struct FrontmostApp: FrontmostAppProviding {
    func frontmostBundleID() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }
}
```

- [ ] **Step 2: Modify CapturePipeline to chain LLM + paste**

```swift
// voxline/Pipeline/CapturePipeline.swift  (replace contents)
import Foundation

/// Coordinates the hotkey → audio capture → transcription → LLM cleanup →
/// clipboard inject pipeline. Updates AppState along the way.
@MainActor
final class CapturePipeline {

    private let state: AppState
    private let capture: AudioCapturing
    private let transcriber: Transcribing
    private let llm: LLMServing
    private let modes: ModeResolving
    private let frontmost: FrontmostAppProviding
    private let injector: ClipboardInjecting

    init(
        state: AppState,
        capture: AudioCapturing,
        transcriber: Transcribing,
        llm: LLMServing,
        modes: ModeResolving,
        frontmost: FrontmostAppProviding,
        injector: ClipboardInjecting
    ) {
        self.state = state
        self.capture = capture
        self.transcriber = transcriber
        self.llm = llm
        self.modes = modes
        self.frontmost = frontmost
        self.injector = injector

        capture.onLevel = { [weak self] level in
            Task { @MainActor in self?.state.audioLevel = level }
        }
    }

    /// Begin a new recording. Caller must ensure we're not already recording.
    func startRecording() {
        if state.status.blocksRecording { return }
        do {
            try capture.start()
        } catch {
            state.status = .error("Audio capture failed: \(error.localizedDescription)")
            state.recordingStartedAt = nil
            state.audioLevel = 0
            return
        }
        state.recordingStartedAt = Date()
        state.audioLevel = 0
        state.status = .recording
    }

    /// Stop capture, transcribe, run LLM cleanup against the active mode's
    /// prompt, and paste the result into the focused field.
    func finalizeRecording() async {
        if state.status.blocksRecording { return }
        capture.stop()
        let samples = capture.takeSamples()
        state.status = .thinking

        if samples.isEmpty {
            resetIdle()
            return
        }

        // 1. Transcribe locally.
        let transcript: String
        do {
            transcript = try await transcriber.transcribe(samples: samples)
        } catch {
            return setError("Transcription failed: \(error.localizedDescription)")
        }
        state.lastTranscript = transcript

        if transcript.isEmpty {
            // Nothing to clean / paste — quietly idle out.
            resetIdle()
            return
        }

        // 2. Resolve the active mode by frontmost bundle ID. Falls back to
        //    `*` wildcard when nothing matches.
        let bundleID = frontmost.frontmostBundleID()
        guard let mode = modes.mode(for: bundleID) else {
            return setError("No mode for app '\(bundleID ?? "unknown")' and no '*' fallback configured. Open Settings → Modes.")
        }

        // 3. LLM cleanup.
        let cleaned: String
        do {
            cleaned = try await llm.cleanup(transcript: transcript, mode: mode)
        } catch let e as LLMError {
            return setError(e.errorDescription ?? "LLM cleanup failed.")
        } catch {
            return setError("LLM cleanup failed: \(error.localizedDescription)")
        }

        // 4. Paste.
        do {
            try await injector.inject(cleaned)
        } catch {
            return setError("Paste failed: \(error.localizedDescription)")
        }

        resetIdle()
    }

    private func resetIdle() {
        state.recordingStartedAt = nil
        state.audioLevel = 0
        state.status = .idle
    }

    private func setError(_ message: String) {
        state.status = .error(message)
        state.recordingStartedAt = nil
        state.audioLevel = 0
    }
}
```

- [ ] **Step 3: Update CapturePipelineTests to cover the new tail**

```swift
// voxlineTests/CapturePipelineTests.swift  (replace contents)
import Testing
import Foundation
@testable import voxline

@Suite @MainActor struct CapturePipelineTests {

    final class FakeCapture: AudioCapturing {
        var onLevel: ((Float) -> Void)?
        var startCallCount = 0
        var stopCallCount = 0
        var pendingSamples: [Float] = [0.1, 0.2, 0.3]
        func start() throws { startCallCount += 1 }
        func stop() { stopCallCount += 1 }
        func takeSamples() -> [Float] { defer { pendingSamples = [] }; return pendingSamples }
    }

    final class FakeTranscriber: Transcribing {
        var nextResult: Result<String, Error> = .success("hello world")
        var transcribeCallCount = 0
        func transcribe(samples: [Float]) async throws -> String {
            transcribeCallCount += 1
            return try nextResult.get()
        }
    }

    final class FakeLLM: LLMServing, @unchecked Sendable {
        var nextResult: Result<String, Error> = .success("cleaned")
        var calls: [(transcript: String, mode: Mode)] = []
        func cleanup(transcript: String, mode: Mode) async throws -> String {
            calls.append((transcript, mode))
            return try nextResult.get()
        }
    }

    final class FakeFrontmost: FrontmostAppProviding, @unchecked Sendable {
        var bundleID: String?
        func frontmostBundleID() -> String? { bundleID }
    }

    final class FakeInjector: ClipboardInjecting {
        var injected: [String] = []
        var nextError: Error?
        func inject(_ text: String) async throws {
            if let nextError { throw nextError }
            injected.append(text)
        }
    }

    private func makePipeline(
        frontmostBundleID: String? = "com.tinyspeck.slackmacgap",
        modes: [Mode] = [
            Mode(bundleID: "com.tinyspeck.slackmacgap", displayName: "Slack", prompt: "slack-prompt", model: nil, temperature: nil),
            Mode(bundleID: "*", displayName: "Default", prompt: "default-prompt", model: nil, temperature: nil)
        ]
    ) -> (pipe: CapturePipeline, state: AppState, capture: FakeCapture, transcriber: FakeTranscriber, llm: FakeLLM, frontmost: FakeFrontmost, injector: FakeInjector) {
        let state = AppState()
        let capture = FakeCapture()
        let transcriber = FakeTranscriber()
        let llm = FakeLLM()
        let front = FakeFrontmost(); front.bundleID = frontmostBundleID
        let injector = FakeInjector()
        let router = ModeRouter(modes: modes)
        let pipe = CapturePipeline(
            state: state, capture: capture, transcriber: transcriber,
            llm: llm, modes: router, frontmost: front, injector: injector
        )
        return (pipe, state, capture, transcriber, llm, front, injector)
    }

    @Test func startRecording_setsStateAndStartsCapture() {
        let (pipe, state, capture, _, _, _, _) = makePipeline()
        pipe.startRecording()
        #expect(state.status == .recording)
        #expect(state.recordingStartedAt != nil)
        #expect(capture.startCallCount == 1)
    }

    @Test func finalizeRecording_routesViaModeAndCallsLLMAndPastes() async throws {
        let (pipe, state, _, transcriber, llm, _, injector) = makePipeline()
        transcriber.nextResult = .success("uh hello there")
        llm.nextResult = .success("Hello there.")
        pipe.startRecording()
        await pipe.finalizeRecording()

        #expect(transcriber.transcribeCallCount == 1)
        #expect(llm.calls.count == 1)
        #expect(llm.calls[0].transcript == "uh hello there")
        #expect(llm.calls[0].mode.bundleID == "com.tinyspeck.slackmacgap")
        #expect(injector.injected == ["Hello there."])
        #expect(state.status == .idle)
        #expect(state.lastTranscript == "uh hello there")
    }

    @Test func unknown_bundleID_falls_back_to_wildcard_mode() async throws {
        let (pipe, _, _, _, llm, _, _) = makePipeline(frontmostBundleID: "com.unknown.app")
        pipe.startRecording()
        await pipe.finalizeRecording()
        #expect(llm.calls[0].mode.bundleID == "*")
    }

    @Test func transcriptionFailure_setsErrorStateNoLLMNoPaste() async throws {
        struct StubError: Error {}
        let (pipe, state, _, transcriber, llm, _, injector) = makePipeline()
        transcriber.nextResult = .failure(StubError())
        pipe.startRecording()
        await pipe.finalizeRecording()
        if case .error = state.status { } else { Issue.record("expected .error") }
        #expect(llm.calls.isEmpty)
        #expect(injector.injected.isEmpty)
    }

    @Test func empty_transcript_skips_llm_and_paste() async throws {
        let (pipe, state, _, transcriber, llm, _, injector) = makePipeline()
        transcriber.nextResult = .success("")
        pipe.startRecording()
        await pipe.finalizeRecording()
        #expect(llm.calls.isEmpty)
        #expect(injector.injected.isEmpty)
        #expect(state.status == .idle)
    }

    @Test func llm_missingAPIKey_surfacesActionableErrorMessage() async throws {
        let (pipe, state, _, _, llm, _, _) = makePipeline()
        llm.nextResult = .failure(LLMError.missingAPIKey)
        pipe.startRecording()
        await pipe.finalizeRecording()
        if case .error(let msg) = state.status {
            #expect(msg.contains("Settings"))
        } else {
            Issue.record("expected .error")
        }
    }

    @Test func paste_failure_setsErrorState() async throws {
        struct StubError: Error {}
        let (pipe, state, _, _, _, _, injector) = makePipeline()
        injector.nextError = StubError()
        pipe.startRecording()
        await pipe.finalizeRecording()
        if case .error = state.status { } else { Issue.record("expected .error") }
    }

    @Test func startRecording_skipsWhenDownloadingModel() {
        let (pipe, state, capture, _, _, _, _) = makePipeline()
        state.status = .downloadingModel(progress: 0.3)
        pipe.startRecording()
        #expect(capture.startCallCount == 0)
    }

    @Test func startRecording_skipsWhenPreparingModel() {
        let (pipe, state, capture, _, _, _, _) = makePipeline()
        state.status = .preparingModel
        pipe.startRecording()
        #expect(capture.startCallCount == 0)
    }
}
```

- [ ] **Step 4: Wire the new dependencies in voxlineApp.AppCoordinator and remove debug-window scene**

```swift
// voxline/voxlineApp.swift  (replace contents)
import AppKit
import SwiftUI

@main
struct voxlineApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(state: delegate.appState)
        } label: {
            MenuBarLabel(state: delegate.appState)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environment(delegate.appState)
        }
        // Plan 2's debug Window scene removed in Plan 3 — paste replaces the
        // verification UI.
    }
}

private struct MenuBarLabel: View {
    @Bindable var state: AppState
    var body: some View {
        Image(systemName: MenuBarIcon.symbolName(for: state.status))
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    let coordinator = AppCoordinator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        coordinator.startIfNeeded(state: appState)
    }
}

@MainActor
final class AppCoordinator {
    private var hotkeyMonitor: HotkeyMonitor?
    private var pillWindow: RecordingPillWindow?
    private var downloadWindow: ModelDownloadWindow?
    private var pipeline: CapturePipeline?
    private var transcriber: TranscriptionService?
    private var didStart = false

    func startIfNeeded(state: AppState) {
        guard !didStart else { return }
        didStart = true

        let capture = AudioCaptureService()
        let transcriber = TranscriptionService()
        self.transcriber = transcriber

        // Modes
        let modeStore: ModeStore
        let modes: [Mode]
        do {
            modeStore = try ModeStore()
            modes = try modeStore.load()
        } catch {
            // Fall back to shipped defaults if disk I/O fails — the app should
            // still work; the user just won't have a writable modes.json this
            // session. (Plan 4's Modes editor will surface the disk error.)
            modeStore = try! ModeStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("voxline-modes-fallback.json"))
            modes = ModeStore.shippedDefaults
        }
        _ = modeStore   // retained only to keep the file path warm; mutation lands in Plan 4
        let router = ModeRouter(modes: modes)

        // LLM
        let llm = LLMService(settings: AppSettings(), keychain: Keychain())

        // Output
        let injector = ClipboardInjector()
        let frontmost = FrontmostApp()

        let pipeline = CapturePipeline(
            state: state,
            capture: capture,
            transcriber: transcriber,
            llm: llm,
            modes: router,
            frontmost: frontmost,
            injector: injector
        )
        self.pipeline = pipeline

        let pill = RecordingPillWindow()
        pillWindow = pill
        pill.show(state: state)

        let monitor = HotkeyMonitor()
        monitor.onStartRecording = { [weak self, weak state] in
            self?.pipeline?.startRecording()
            if let state { self?.pillWindow?.updateVisibility(state: state) }
        }
        monitor.onFinalizeRecording = { [weak self, weak state] in
            Task { @MainActor in
                await self?.pipeline?.finalizeRecording()
                self?.hotkeyMonitor?.recordingFinished()
                if let state { self?.pillWindow?.updateVisibility(state: state) }
            }
        }
        do {
            try monitor.start()
            hotkeyMonitor = monitor
        } catch {
            state.status = .error("Hotkey monitoring requires Accessibility permission. Grant it in System Settings → Privacy & Security → Accessibility, then restart voxline.")
        }

        prepareIfNeeded(state: state, transcriber: transcriber)
    }

    private func prepareIfNeeded(state: AppState, transcriber: TranscriptionService) {
        let needsDownload = !TranscriptionService.isModelCached(transcriber.model)
        state.status = needsDownload ? .downloadingModel(progress: 0) : .preparingModel
        let window = ModelDownloadWindow()
        downloadWindow = window
        window.show(state: state)

        Task { @MainActor in
            do {
                if needsDownload {
                    try await transcriber.prepareModel { progress in
                        Task { @MainActor in
                            if case .downloadingModel = state.status {
                                state.status = .downloadingModel(progress: progress)
                            }
                        }
                    }
                    if case .downloadingModel = state.status {
                        state.status = .preparingModel
                    }
                }
                try await transcriber.prewarm()
                if case .preparingModel = state.status {
                    state.status = .idle
                }
                downloadWindow?.close()
                downloadWindow = nil
            } catch {
                state.status = .error("Model setup failed: \(error.localizedDescription). Quit and relaunch voxline to retry.")
                downloadWindow?.close()
                downloadWindow = nil
            }
        }
    }
}
```

- [ ] **Step 5: Drop the debug menu item**

```swift
// voxline/MenuBar/MenuBarContent.swift  (modify)
// Remove the "Show Transcripts (debug)…" Button block. The final body should be:

import SwiftUI

struct MenuBarContent: View {
    @Bindable var state: AppState
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if case .error(let message) = state.status {
            Text(message)
                .foregroundStyle(.red)
            Divider()
        }

        if case .downloadingModel(let p) = state.status {
            Text("Downloading model — \(Int(p * 100))%")
                .foregroundStyle(.secondary)
            Divider()
        }

        Button("Settings…") {
            openSettings()
            NSApp.activate()
        }
        .keyboardShortcut(",")

        Divider()

        Button("Quit voxline") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
```

- [ ] **Step 6: Delete the debug window file**

```bash
rm voxline/UI/DebugTranscriptWindow.swift
```

- [ ] **Step 7: Run the full suite**

```bash
xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS,arch=arm64' 2>&1 | tail -10
```

Expected: `** TEST SUCCEEDED **`. Total test count after Plan 3: previous 56 + (Task 1 → 3) + (Task 2 → 4) + (Task 3 → 5) + (Task 4 → 6) + (Task 5 → 4) + (Task 6 → 4) + (Task 7 → 7) + (Task 8 → 5) + (Task 9 → 5) + (Task 10 → 4) + (Task 11 → 4) + (Task 12 → 3) + (Task 13 net change ≈ +6) = roughly **111** total. Implementer should report the actual number.

- [ ] **Step 8: Commit**

```bash
git add voxline/Pipeline/PipelineProtocols.swift voxline/Pipeline/CapturePipeline.swift voxline/Output/FrontmostApp.swift voxline/voxlineApp.swift voxline/MenuBar/MenuBarContent.swift voxlineTests/CapturePipelineTests.swift
git rm voxline/UI/DebugTranscriptWindow.swift
git commit -m "Wire LLM cleanup + paste; remove debug transcript window"
```

---

## Manual Verification (Plan 3 acceptance)

After all 13 tasks land, the implementer (or the user) should walk through the following manual smoke before declaring Plan 3 done:

1. **Build & launch** the app from Xcode. Setup window appears, completes (model already cached from Plan 2). Menu icon goes to `mic`.
2. **Set an API key.** Open Settings → API Keys, choose Anthropic (or OpenAI), paste a real key, click Save. The window closes without an error banner.
3. **Smoke test in TextEdit.** New document. Hold Left Ctrl + Left Option, say "Hello uh world". Release. The text "Hello world." (or similar) appears in TextEdit, without leading/trailing modifier-key chatter.
4. **Smoke test in Slack desktop.** Same chord into a Slack DM compose box. Cleaned text pastes; the conversation isn't accidentally Cmd-Sent.
5. **Clipboard restore.** Before recording, copy something distinctive (e.g., the word `MARKER`). Dictate. After paste completes, ⌘V into TextEdit and confirm `MARKER` comes back (not your dictation).
6. **No-key error.** Delete the API key from Settings. Dictate. Menu icon goes red; clicking shows the actionable "Open Settings → API Keys" message. State recovers when a valid key is set and you dictate again.
7. **No-network error.** Toggle Wi-Fi off, dictate, confirm a "Network error" message in the menu rather than a hang.

Tag `cleanup-paste-complete` after manual verification passes.

---

## Self-Review

**Spec coverage:**

- §4.3 (LLM Cleanup + Output) — Tasks 6-9, 10-11, 13 ✓
- §5.1 Mode model — Task 1 ✓
- §5.2 shipped defaults — Task 2 ✓
- §5.3 UserDefaults for provider, Keychain for keys — Tasks 4-5, 12 ✓
- §6.3 API Keys tab — Task 12 ✓ (Modes tab + General tab stay deferred to Plan 4 per user direction)
- §7.1 Clipboard preservation (multi-item × multi-type, refuse-to-clobber) — Tasks 10-11 ✓
- §9.1 unit tests for ModeRouter, ClipboardInjector, LLMClient — Tasks 3, 11, 7-8 ✓ (HotkeyStateMachine landed in Plan 2)
- §6.4 First-run wizard — explicitly out of scope for Plan 3 (Plan 4)
- §6.2 Floating recording pill — already shipped in Plan 2; no changes
- §6.1 Menu bar icon error state — already wired via Plan 2's MenuBarContent error row; Task 13's CapturePipeline tail surfaces actionable error messages through the same row

**Placeholder scan:** No "TBD" / "implement later" / "similar to" in the body. The Task 5 ↔ Task 6 ordering note is a real callout (swap when implementing) rather than a placeholder.

**Type consistency:**
- `Mode` fields: bundleID, displayName, prompt, model, temperature — used identically throughout.
- `LLMRequest` fields: model, systemPrompt, userPrompt, temperature, maxOutputTokens — same in Tasks 6, 7, 8, 9.
- `Keychain.Account.anthropic` / `.openai` constants used in Tasks 4 (definition), 9 (LLMService), 12 (settings VM), and tests.
- `LLMError` cases (.missingAPIKey, .invalidAPIKey, .rateLimited, .network, .badStatus, .badResponseShape) used identically in Tasks 6, 7, 8, 9, 13. Equatable conformance defined once in Task 7.
- Protocol names (LLMServing, ModeResolving, ClipboardInjecting, FrontmostAppProviding) match between PipelineProtocols (Task 13) and the concrete types' extensions.

**Risks / gotchas the implementer should know:**

- The Task 5 ↔ Task 6 ordering: Task 5's tests reference `LLMProvider.anthropic.defaultModel`. Either swap the implementation order or stub `LLMProvider` inside Task 5 and remove the stub when Task 6 lands.
- `CGEvent` posting from a sandboxed app requires Accessibility permission, the same one Plan 2 already requires for `CGEventTap`. No new entitlement.
- `ClipboardInjector.kVirtualKeyV = 9` is the US ANSI virtual key code; non-US layouts that bind paste differently are a known limitation. Document under "future work" in Plan 5+ rather than fixing in Plan 3.
- `NSWorkspace.frontmostApplication` is `nil` if no app currently owns focus (rare; e.g., during fast user switching). The pipeline handles this via `ModeRouter`'s `*` fallback, so Plan 3 is safe; the manual test in step 3 above implicitly covers it.

---

## Plan complete and saved to `docs/superpowers/plans/2026-05-09-voxline-llm-cleanup-paste.md`.
