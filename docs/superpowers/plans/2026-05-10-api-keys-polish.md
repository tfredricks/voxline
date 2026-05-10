# API Keys Tab — A+ Polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring the API Keys settings tab to A+ — instant-apply via save-on-blur, hygienic state management, per-provider Test buttons, reveal toggles, help links, prefix validation, and a "Saved" indicator. Move the Provider picker out of API Keys into General where it belongs.

**Architecture:** Save-on-blur uses SwiftUI `@FocusState` to detect field-blur and persist the field's value at that moment. Each field is committed independently (one keychain write per field, on demand). The Provider picker moves to GeneralSettingsView/VM/Snapshot/Applier — API Keys tab becomes purely about credentials. `testConnection` is split per-provider, scoped to its own key, and uses an injectable `LLMClient` factory for tests.

**Tech Stack:** SwiftUI (`@Observable` MVVM, `@FocusState`), Keychain (existing wrapper), Swift Testing.

**Decisions baked in (from review):**
- **A. Save model:** save-on-blur (commit on focus loss), not Save-button, not per-keystroke. Avoids partial-key writes; matches macOS HIG.
- **B. Provider picker location:** MOVE to General. API Keys tab is purely credentials.
- **C. UX polish:** reveal toggles, per-provider Get-key links, prefix validation (sk-ant-/sk-), whitespace trim, "Saved" pill.

**Out of scope (deferred):**
- Model picker (per-provider model override) — AppSettings supports it, no UI; punt to v2 when there's demand
- Last-tested-timestamp persistence — purely cosmetic; punt
- "Remove key" explicit button — empty field + blur already deletes; the Saved pill makes this clearer

---

## File Map

**Modified:**
- `voxline/Settings/APIKeysSettingsView.swift` — drop Save button, add FocusState, per-provider Test buttons, reveal toggles, help links, Saved/Unsaved pill, prefix warning
- `voxline/Settings/APIKeysSettingsViewModel.swift` — split combined `save()` into `commitAnthropic()` / `commitOpenAI()`; trim on commit; clear `testResult` and `lastError` on key change; scope `testConnection` to single provider; inject `clientFactory`; remove provider field; inject via init
- `voxline/Settings/GeneralSettingsView.swift` — add "Cleanup model" section with Provider picker
- `voxline/Settings/GeneralSettingsViewModel.swift` — add `provider: LLMProvider` property with didSet+commit
- `voxline/Settings/GeneralSettingsApplier.swift` — add `provider: LLMProvider` to `GeneralSettingsSnapshot`
- `voxline/voxlineApp.swift` — wire APIKeysSettingsViewModel injection in SettingsView; ensure `apply(_:)` reads provider from snapshot if needed
- `voxlineTests/APIKeysSettingsViewModelTests.swift` — adapt to per-key commit API; add `testConnection` tests with stub factory; remove provider-related tests (those move)
- `voxlineTests/GeneralSettingsViewModelTests.swift` — add provider-property test

**New:**
- (no new files)

---

### Task 1: VM hygiene — trim, clear stale state, inject clientFactory, inject VM, scrub Preview

Foundational cleanup that every later task depends on. Splits the combined `save()` into per-key commit methods. Trims on commit. Clears stale `testResult`/`lastError` when a key changes. Adds an injectable `clientFactory` for testing `testConnection`. Constructs the VM in `voxlineApp.swift` like `GeneralSettingsViewModel` is.

**Files:**
- Modify: `voxline/Settings/APIKeysSettingsViewModel.swift`
- Modify: `voxline/Settings/APIKeysSettingsView.swift`
- Modify: `voxline/voxlineApp.swift`
- Modify: `voxlineTests/APIKeysSettingsViewModelTests.swift`

- [ ] **Step 1: Write failing tests for per-key commit + auto-clear**

In `voxlineTests/APIKeysSettingsViewModelTests.swift`, add tests inside the `@Suite`:

```swift
@Test func commit_anthropic_persists_only_anthropic_and_trims() throws {
    let kc = keychain()
    defer { try? kc.deleteAll() }
    let vm = APIKeysSettingsViewModel(settings: AppSettings(defaults: defaultsSuite()), keychain: kc)
    vm.anthropicKey = "  sk-ant-123\n "
    vm.openaiKey    = "should-not-write"
    vm.commitAnthropic()
    #expect(try kc.string(forKey: Keychain.Account.anthropic) == "sk-ant-123")
    #expect(try kc.string(forKey: Keychain.Account.openai) == nil)  // openai untouched
}

@Test func commit_openai_persists_only_openai_and_trims() throws {
    let kc = keychain()
    defer { try? kc.deleteAll() }
    let vm = APIKeysSettingsViewModel(settings: AppSettings(defaults: defaultsSuite()), keychain: kc)
    vm.openaiKey = "\tsk-openai-xyz \n"
    vm.commitOpenAI()
    #expect(try kc.string(forKey: Keychain.Account.openai) == "sk-openai-xyz")
}

@Test func empty_commit_deletes_keychain_entry() throws {
    let kc = keychain()
    try kc.set("preexisting", forKey: Keychain.Account.anthropic)
    defer { try? kc.deleteAll() }
    let vm = APIKeysSettingsViewModel(settings: AppSettings(defaults: defaultsSuite()), keychain: kc)
    vm.anthropicKey = "   "   // whitespace-only counts as empty after trim
    vm.commitAnthropic()
    #expect(try kc.string(forKey: Keychain.Account.anthropic) == nil)
}

@Test func test_result_resets_when_relevant_key_changes() {
    let vm = APIKeysSettingsViewModel(settings: AppSettings(defaults: defaultsSuite()), keychain: keychain())
    vm.testResult = .success(.anthropic)
    vm.anthropicKey = "new-key"
    #expect(vm.testResult == .untested)
}

@Test func test_result_for_other_provider_persists_when_unrelated_key_changes() {
    let vm = APIKeysSettingsViewModel(settings: AppSettings(defaults: defaultsSuite()), keychain: keychain())
    vm.testResult = .success(.anthropic)
    vm.openaiKey = "new-openai-key"   // unrelated to anthropic test result
    #expect(vm.testResult == .success(.anthropic))
}

@Test func last_error_clears_when_any_key_changes() {
    let vm = APIKeysSettingsViewModel(settings: AppSettings(defaults: defaultsSuite()), keychain: keychain())
    vm.lastError = "Save failed: keychain unavailable"
    vm.anthropicKey = "x"
    #expect(vm.lastError == nil)
}
```

(Note: `testResult` becomes a typed enum carrying which provider it pertains to — `success(LLMProvider)` / `failed(LLMProvider, String)` / `untested`. Old tests using bare `.success` need updating in the same step.)

Update the EXISTING tests in this file:
- DELETE `loads_existing_keys_and_provider_on_init` and `save_persists_provider_and_keys` — provider moves to General in Task 2; commit-flow tests above replace the save test.
- KEEP `save_with_empty_key_deletes_keychain_entry` but rename to `save_with_empty_key_deletes_keychain_entry_legacy_compat` and adapt to call `commitAnthropic()` (or simply replace with the `empty_commit_deletes_keychain_entry` test above and delete the old one).

Recommended: delete both existing tests and rely on the new ones above.

- [ ] **Step 2: Run tests — expect compile failure**

Run: `xcodebuild -scheme voxline -destination 'platform=macOS' test -only-testing:voxlineTests/APIKeysSettingsViewModelTests 2>&1 | tail -40`
Expected: FAIL — `commitAnthropic`, `commitOpenAI`, the new `testResult` shape, and the auto-clear behavior do not exist.

- [ ] **Step 3: Rewrite the VM**

Replace `voxline/Settings/APIKeysSettingsViewModel.swift`:

```swift
import Foundation
import Observation

enum APIKeyTestResult: Equatable {
    case untested
    case success(LLMProvider)
    case failed(LLMProvider, String)
}

typealias LLMClientFactory = (LLMProvider, String) -> LLMClient

@Observable
@MainActor
final class APIKeysSettingsViewModel {

    var anthropicKey: String { didSet { onKeyChanged(.anthropic) } }
    var openaiKey: String    { didSet { onKeyChanged(.openai) } }

    var lastError: String?
    var testResult: APIKeyTestResult = .untested
    var testing: LLMProvider?  // which provider's test is in flight, nil = none

    private let keychain: Keychain
    private let clientFactory: LLMClientFactory

    init(
        keychain: Keychain = Keychain(),
        clientFactory: @escaping LLMClientFactory = { provider, key in
            switch provider {
            case .anthropic: return AnthropicClient(apiKey: key)
            case .openai:    return OpenAIClient(apiKey: key)
            }
        }
    ) {
        self.keychain = keychain
        self.clientFactory = clientFactory
        self.anthropicKey = (try? keychain.string(forKey: Keychain.Account.anthropic)) ?? ""
        self.openaiKey    = (try? keychain.string(forKey: Keychain.Account.openai)) ?? ""
    }

    /// Persist the Anthropic key. Whitespace is trimmed; an empty/whitespace
    /// value deletes the keychain entry.
    func commitAnthropic() {
        persist(value: anthropicKey, account: Keychain.Account.anthropic)
    }

    /// Persist the OpenAI key. Same rules as commitAnthropic.
    func commitOpenAI() {
        persist(value: openaiKey, account: Keychain.Account.openai)
    }

    /// Issue a tiny no-op LLM call to verify the saved key for `provider`.
    /// Does NOT persist; commitX is the caller's responsibility (typically
    /// already done via save-on-blur before the user clicks Test).
    func testConnection(_ provider: LLMProvider) async {
        testing = provider
        defer { testing = nil }
        let key = (try? keychain.string(forKey: account(for: provider))) ?? ""
        guard !key.isEmpty else {
            testResult = .failed(provider, "No API key set.")
            return
        }
        let request = LLMRequest(
            model: provider.defaultModel,
            systemPrompt: "Return the word 'ok' and nothing else.",
            userPrompt: "ping",
            temperature: 0
        )
        do {
            _ = try await clientFactory(provider, key).cleanup(request)
            testResult = .success(provider)
        } catch let err as LLMError {
            testResult = .failed(provider, err.errorDescription ?? "Failed")
        } catch {
            testResult = .failed(provider, error.localizedDescription)
        }
    }

    /// True when the field's current value matches what's persisted in
    /// keychain. Used to drive the "Saved"/"Unsaved" pill.
    func isPersisted(_ provider: LLMProvider) -> Bool {
        let saved = (try? keychain.string(forKey: account(for: provider))) ?? ""
        let live = trimmed(provider == .anthropic ? anthropicKey : openaiKey)
        return saved == live
    }

    private func onKeyChanged(_ provider: LLMProvider) {
        // Clear stale test result if it pertains to this provider.
        if case .success(let p) = testResult, p == provider { testResult = .untested }
        if case .failed(let p, _) = testResult, p == provider { testResult = .untested }
        // Clear save error any time a key is edited.
        lastError = nil
    }

    private func persist(value: String, account: String) {
        let v = trimmed(value)
        do {
            if v.isEmpty {
                try keychain.delete(forKey: account)
            } else {
                try keychain.set(v, forKey: account)
            }
        } catch {
            lastError = "Save failed: \(error.localizedDescription)"
        }
    }

    private func account(for provider: LLMProvider) -> String {
        switch provider {
        case .anthropic: return Keychain.Account.anthropic
        case .openai:    return Keychain.Account.openai
        }
    }

    private func trimmed(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
```

Notes:
- `provider` is removed from this VM entirely (moves in Task 2).
- `save()` is removed entirely. Replaced by `commitAnthropic()` and `commitOpenAI()`.
- `testing` is now `LLMProvider?` (which one is being tested) instead of a bare `Bool` — supports per-provider Test buttons in Task 4.
- `clientFactory` defaults to the real implementation; tests inject a stub.
- `lastError` is auto-cleared on any key edit. Save errors set it; the View renders it.

- [ ] **Step 4: Update the View to construct VM via injection (preserve current UI behavior)**

This step is a *minimal* update — just enough to make the existing UI compile against the new VM, before larger Task 3/4/5 rewrites land. Replace `voxline/Settings/APIKeysSettingsView.swift`:

```swift
import SwiftUI

struct APIKeysSettingsView: View {

    @State private var vm: APIKeysSettingsViewModel

    init(vm: APIKeysSettingsViewModel) {
        _vm = State(wrappedValue: vm)
    }

    var body: some View {
        Form {
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
                Button("Save") {
                    vm.commitAnthropic()
                    vm.commitOpenAI()
                }
                .keyboardShortcut(.defaultAction)
            }

            HStack {
                Button("Test Anthropic") { Task { await vm.testConnection(.anthropic) } }
                    .disabled(vm.testing != nil || vm.anthropicKey.isEmpty)
                Button("Test OpenAI") { Task { await vm.testConnection(.openai) } }
                    .disabled(vm.testing != nil || vm.openaiKey.isEmpty)
                if vm.testing != nil { ProgressView().controlSize(.small) }
                Spacer()
                testResultLabel
            }

            if let err = vm.lastError {
                Text(err).foregroundStyle(.red).font(.callout)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, idealWidth: 540, minHeight: 320, idealHeight: 380)
    }

    @ViewBuilder
    private var testResultLabel: some View {
        switch vm.testResult {
        case .untested: EmptyView()
        case .success(let p):
            Label("\(p.displayName) connected", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green).font(.callout)
        case .failed(_, let msg):
            Label(msg, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red).font(.callout)
        }
    }
}
```

(Note: provider Picker and `#Preview` removed. Save button is still here for now — Task 3 replaces it with save-on-blur. Per-provider Test buttons land in this step because the VM contract already supports them.)

- [ ] **Step 5: Update voxlineApp.swift to inject the VM**

In `voxline/voxlineApp.swift`, change the `Settings` scene block:

```swift
Settings {
    SettingsView(
        generalVM: GeneralSettingsViewModel(applier: delegate.coordinator),
        apiKeysVM: APIKeysSettingsViewModel()
    )
    .environment(delegate.appState)
}
```

And update `voxline/Settings/SettingsView.swift`:

```swift
import SwiftUI

struct SettingsView: View {
    let generalVM: GeneralSettingsViewModel
    let apiKeysVM: APIKeysSettingsViewModel

    var body: some View {
        TabView {
            GeneralSettingsView(vm: generalVM)
                .tabItem { Label("General", systemImage: "gear") }

            APIKeysSettingsView(vm: apiKeysVM)
                .tabItem { Label("API Keys", systemImage: "key") }
        }
    }
}
```

- [ ] **Step 6: Run all tests**

Run: `xcodebuild -scheme voxline -destination 'platform=macOS' test 2>&1 | tail -40`
Expected: PASS. The new APIKeysSettingsViewModelTests pass; existing tests in other suites still pass.

- [ ] **Step 7: Commit**

```bash
git add voxline/Settings/APIKeysSettingsViewModel.swift voxline/Settings/APIKeysSettingsView.swift voxline/Settings/SettingsView.swift voxline/voxlineApp.swift voxlineTests/APIKeysSettingsViewModelTests.swift
git commit -m "api keys: per-key commit, trim, auto-clear stale state, injectable client factory"
```

---

### Task 2: Move Provider picker from API Keys to General

The active LLM provider is a *General* setting (which model the app calls). It doesn't belong on the credentials tab. Adds a "Cleanup model" section to General with a Picker, wired through GeneralSettingsViewModel/Snapshot/Applier.

**Files:**
- Modify: `voxline/Settings/GeneralSettingsViewModel.swift`
- Modify: `voxline/Settings/GeneralSettingsApplier.swift`
- Modify: `voxline/Settings/GeneralSettingsView.swift`
- Modify: `voxline/voxlineApp.swift` (AppCoordinator's `apply(_:)` may need to handle provider)
- Modify: `voxlineTests/GeneralSettingsViewModelTests.swift`

- [ ] **Step 1: Write failing test for provider on the General VM**

Append to `voxlineTests/GeneralSettingsViewModelTests.swift`:

```swift
@Test func provider_change_persists_and_calls_applier() {
    let d = defaults()
    let settings = AppSettings(defaults: d)
    let applier = RecordingApplier()
    let vm = GeneralSettingsViewModel(settings: settings, applier: applier)

    vm.provider = .openai
    #expect(applier.applied?.provider == .openai)
    #expect(AppSettings(defaults: d).llmProvider == .openai)
}
```

- [ ] **Step 2: Run — expect compile failure**

Run: `xcodebuild -scheme voxline -destination 'platform=macOS' test -only-testing:voxlineTests/GeneralSettingsViewModelTests 2>&1 | tail -25`
Expected: FAIL — `vm.provider` does not exist; `applier.applied?.provider` does not exist.

- [ ] **Step 3: Add `provider` to the snapshot**

In `voxline/Settings/GeneralSettingsApplier.swift`, replace the `GeneralSettingsSnapshot` struct with:

```swift
struct GeneralSettingsSnapshot: Equatable {
    let chord: HotkeyChord
    let audioInputDeviceUID: String?
    let whisperModel: WhisperModel
    let playHotkeySounds: Bool
    let provider: LLMProvider
}
```

- [ ] **Step 4: Add `provider` to the General VM**

In `voxline/Settings/GeneralSettingsViewModel.swift`:

Add property next to the other 4 didSet-observed properties:
```swift
var provider: LLMProvider { didSet { if loaded { commit() } } }
```

In `init`, before `loaded = true`:
```swift
self.provider = settings.llmProvider
```

In `commit()`, add to the AppSettings write and the snapshot:
```swift
s.llmProvider = provider
// ... existing assignments ...
applier.apply(GeneralSettingsSnapshot(
    chord: chord,
    audioInputDeviceUID: audioInputDeviceUID,
    whisperModel: whisperModel,
    playHotkeySounds: playHotkeySounds,
    provider: provider
))
```

In `resetToDefaults()`, before the closing `commit()`:
```swift
provider = .anthropic
```

- [ ] **Step 5: Update AppCoordinator's `apply(_:)`**

In `voxline/voxlineApp.swift`'s `extension AppCoordinator: GeneralSettingsApplier`, the existing applier doesn't need to do anything with `provider` directly — `LLMService` reads `AppSettings.llmProvider` per call. So no code change is required, but add a comment documenting that:

```swift
// snapshot.provider is consumed by LLMService at the next dictation;
// no per-snapshot action needed here.
```

- [ ] **Step 6: Update General view to include the Picker**

In `voxline/Settings/GeneralSettingsView.swift`, add a new section between "Speech recognition" and "Feedback":

```swift
Section("Cleanup model") {
    Picker("Provider", selection: $vm.provider) {
        ForEach(LLMProvider.allCases, id: \.self) { p in
            Text(p.displayName).tag(p)
        }
    }
    .pickerStyle(.segmented)
}
```

- [ ] **Step 7: Run all tests**

Run: `xcodebuild -scheme voxline -destination 'platform=macOS' test 2>&1 | tail -40`
Expected: PASS. All existing General + API Keys tests continue to pass; new provider test passes.

- [ ] **Step 8: Commit**

```bash
git add voxline/Settings/GeneralSettingsViewModel.swift voxline/Settings/GeneralSettingsApplier.swift voxline/Settings/GeneralSettingsView.swift voxline/voxlineApp.swift voxlineTests/GeneralSettingsViewModelTests.swift
git commit -m "settings: move LLM provider picker from API Keys to General"
```

---

### Task 3: Save-on-blur for API key fields (drop the Save button)

Replace the explicit Save button with auto-commit on focus loss. Uses `@FocusState` to track which field is focused; when focus leaves a field, that field commits independently.

**Files:**
- Modify: `voxline/Settings/APIKeysSettingsView.swift`

- [ ] **Step 1: Replace the View with FocusState wiring**

Replace `voxline/Settings/APIKeysSettingsView.swift`:

```swift
import SwiftUI

struct APIKeysSettingsView: View {

    private enum Field: Hashable { case anthropic, openai }

    @State private var vm: APIKeysSettingsViewModel
    @FocusState private var focused: Field?

    init(vm: APIKeysSettingsViewModel) {
        _vm = State(wrappedValue: vm)
    }

    var body: some View {
        Form {
            Section("Anthropic") {
                SecureField("API key", text: $vm.anthropicKey)
                    .textContentType(.password)
                    .focused($focused, equals: .anthropic)
                    .onSubmit { vm.commitAnthropic() }
            }
            Section("OpenAI") {
                SecureField("API key", text: $vm.openaiKey)
                    .textContentType(.password)
                    .focused($focused, equals: .openai)
                    .onSubmit { vm.commitOpenAI() }
            }

            HStack {
                Button("Test Anthropic") { Task { await vm.testConnection(.anthropic) } }
                    .disabled(vm.testing != nil || vm.anthropicKey.isEmpty)
                Button("Test OpenAI") { Task { await vm.testConnection(.openai) } }
                    .disabled(vm.testing != nil || vm.openaiKey.isEmpty)
                if vm.testing != nil { ProgressView().controlSize(.small) }
                Spacer()
                testResultLabel
            }

            if let err = vm.lastError {
                Text(err).foregroundStyle(.red).font(.callout)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, idealWidth: 540, minHeight: 320, idealHeight: 380)
        .onChange(of: focused) { previous, _ in
            // Field just lost focus — persist its current value.
            switch previous {
            case .anthropic: vm.commitAnthropic()
            case .openai:    vm.commitOpenAI()
            case .none:      break
            }
        }
        .onDisappear {
            // Settings window closing while a field is still focused: commit.
            switch focused {
            case .anthropic: vm.commitAnthropic()
            case .openai:    vm.commitOpenAI()
            case .none:      break
            }
        }
    }

    @ViewBuilder
    private var testResultLabel: some View {
        switch vm.testResult {
        case .untested: EmptyView()
        case .success(let p):
            Label("\(p.displayName) connected", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green).font(.callout)
        case .failed(_, let msg):
            Label(msg, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red).font(.callout)
        }
    }
}
```

Key behaviors:
- `.onSubmit` (Enter key) commits.
- `.onChange(of: focused)` commits the *previous* field when focus moves anywhere — including to a button, to the other field, or to nothing.
- `.onDisappear` commits if the user closes Settings while a field is focused.
- The Save button is gone. The HStack with Test buttons is kept and now leads.

- [ ] **Step 2: Build and run all tests**

Run: `xcodebuild -scheme voxline -destination 'platform=macOS' test 2>&1 | tail -40`
Expected: PASS. No new tests in this step (the VM contract was tested in Task 1; this step is pure View change).

- [ ] **Step 3: Commit**

```bash
git add voxline/Settings/APIKeysSettingsView.swift
git commit -m "api keys: save-on-blur, drop Save button (macOS HIG)"
```

---

### Task 4: testConnection coverage with stub LLMClient factory

Now that `clientFactory` is injectable, add tests for the testConnection success/failure paths so this load-bearing method is no longer at zero coverage.

**Files:**
- Modify: `voxlineTests/APIKeysSettingsViewModelTests.swift`

- [ ] **Step 1: Add test stub LLMClient and tests**

Append to `voxlineTests/APIKeysSettingsViewModelTests.swift`:

```swift
private struct StubClient: LLMClient {
    enum Mode { case ok, fail(LLMError) }
    let mode: Mode
    func cleanup(_ request: LLMRequest) async throws -> String {
        switch mode {
        case .ok: return "ok"
        case .fail(let err): throw err
        }
    }
}

@Test func test_connection_success_sets_success_for_provider() async throws {
    let kc = keychain()
    try kc.set("k", forKey: Keychain.Account.anthropic)
    defer { try? kc.deleteAll() }
    let vm = APIKeysSettingsViewModel(
        keychain: kc,
        clientFactory: { _, _ in StubClient(mode: .ok) }
    )
    await vm.testConnection(.anthropic)
    if case .success(let p) = vm.testResult { #expect(p == .anthropic) } else { Issue.record("expected .success(.anthropic), got \(vm.testResult)") }
}

@Test func test_connection_fail_sets_failed_for_provider_with_message() async throws {
    let kc = keychain()
    try kc.set("k", forKey: Keychain.Account.openai)
    defer { try? kc.deleteAll() }
    let vm = APIKeysSettingsViewModel(
        keychain: kc,
        clientFactory: { _, _ in StubClient(mode: .fail(.invalidAPIKey)) }
    )
    await vm.testConnection(.openai)
    if case .failed(let p, let msg) = vm.testResult {
        #expect(p == .openai)
        #expect(msg.contains("rejected") || msg.contains("API key"))
    } else {
        Issue.record("expected .failed(.openai, _), got \(vm.testResult)")
    }
}

@Test func test_connection_no_key_sets_failed_without_calling_factory() async throws {
    let kc = keychain()
    defer { try? kc.deleteAll() }
    var calls = 0
    let vm = APIKeysSettingsViewModel(
        keychain: kc,
        clientFactory: { _, _ in calls += 1; return StubClient(mode: .ok) }
    )
    await vm.testConnection(.anthropic)
    #expect(calls == 0)
    if case .failed(let p, let msg) = vm.testResult {
        #expect(p == .anthropic)
        #expect(msg == "No API key set.")
    } else {
        Issue.record("expected .failed(.anthropic, \"No API key set.\")")
    }
}
```

- [ ] **Step 2: Run tests — expect PASS**

Run: `xcodebuild -scheme voxline -destination 'platform=macOS' test -only-testing:voxlineTests/APIKeysSettingsViewModelTests 2>&1 | tail -30`
Expected: all pass.

- [ ] **Step 3: Commit**

```bash
git add voxlineTests/APIKeysSettingsViewModelTests.swift
git commit -m "api keys: cover testConnection success/failure/no-key paths"
```

---

### Task 5: UX polish — reveal toggle, help links, prefix warning, Saved/Unsaved pill

Final polish task. Per-field reveal eye icon, "Get a key →" link per provider, soft prefix-mismatch warning, and a Saved/Unsaved status pill driven by `vm.isPersisted(_:)`.

**Files:**
- Modify: `voxline/Settings/APIKeysSettingsView.swift`

- [ ] **Step 1: Replace the View with the polished layout**

Replace `voxline/Settings/APIKeysSettingsView.swift`:

```swift
import SwiftUI

struct APIKeysSettingsView: View {

    private enum Field: Hashable { case anthropic, openai }

    @State private var vm: APIKeysSettingsViewModel
    @State private var anthropicRevealed = false
    @State private var openaiRevealed = false
    @FocusState private var focused: Field?

    init(vm: APIKeysSettingsViewModel) {
        _vm = State(wrappedValue: vm)
    }

    var body: some View {
        Form {
            keySection(
                title: "Anthropic",
                provider: .anthropic,
                key: $vm.anthropicKey,
                revealed: $anthropicRevealed,
                getKeyURL: URL(string: "https://console.anthropic.com/settings/keys")!,
                expectedPrefix: "sk-ant-"
            )

            keySection(
                title: "OpenAI",
                provider: .openai,
                key: $vm.openaiKey,
                revealed: $openaiRevealed,
                getKeyURL: URL(string: "https://platform.openai.com/api-keys")!,
                expectedPrefix: "sk-"
            )

            HStack {
                Button("Test Anthropic") { Task { await vm.testConnection(.anthropic) } }
                    .disabled(vm.testing != nil || vm.anthropicKey.isEmpty)
                Button("Test OpenAI") { Task { await vm.testConnection(.openai) } }
                    .disabled(vm.testing != nil || vm.openaiKey.isEmpty)
                if vm.testing != nil { ProgressView().controlSize(.small) }
                Spacer()
                testResultLabel
            }

            if let err = vm.lastError {
                Text(err).foregroundStyle(.red).font(.callout)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, idealWidth: 540, minHeight: 380, idealHeight: 460)
        .onChange(of: focused) { previous, _ in
            switch previous {
            case .anthropic: vm.commitAnthropic()
            case .openai:    vm.commitOpenAI()
            case .none:      break
            }
        }
        .onDisappear {
            switch focused {
            case .anthropic: vm.commitAnthropic()
            case .openai:    vm.commitOpenAI()
            case .none:      break
            }
        }
    }

    @ViewBuilder
    private func keySection(
        title: String,
        provider: LLMProvider,
        key: Binding<String>,
        revealed: Binding<Bool>,
        getKeyURL: URL,
        expectedPrefix: String
    ) -> some View {
        let field: Field = (provider == .anthropic) ? .anthropic : .openai
        Section(title) {
            HStack {
                Group {
                    if revealed.wrappedValue {
                        TextField("API key", text: key)
                    } else {
                        SecureField("API key", text: key)
                    }
                }
                .textContentType(.password)
                .focused($focused, equals: field)
                .onSubmit {
                    if provider == .anthropic { vm.commitAnthropic() } else { vm.commitOpenAI() }
                }

                Button {
                    revealed.wrappedValue.toggle()
                } label: {
                    Image(systemName: revealed.wrappedValue ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .help(revealed.wrappedValue ? "Hide key" : "Reveal key")

                statusPill(for: provider, value: key.wrappedValue)
            }

            HStack(spacing: 8) {
                Link("Get a \(title) key →", destination: getKeyURL)
                    .font(.callout)
                Spacer()
                if !key.wrappedValue.isEmpty,
                   !key.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(expectedPrefix) {
                    Label("Expected prefix \(expectedPrefix)", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
            }
        }
    }

    @ViewBuilder
    private func statusPill(for provider: LLMProvider, value: String) -> some View {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            EmptyView()
        } else if vm.isPersisted(provider) {
            Text("Saved")
                .font(.caption)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.green.opacity(0.2), in: Capsule())
                .foregroundStyle(.green)
        } else {
            Text("Unsaved")
                .font(.caption)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.orange.opacity(0.2), in: Capsule())
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var testResultLabel: some View {
        switch vm.testResult {
        case .untested: EmptyView()
        case .success(let p):
            Label("\(p.displayName) connected", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green).font(.callout)
        case .failed(_, let msg):
            Label(msg, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red).font(.callout)
        }
    }
}
```

Key UX behaviors:
- Per-field eye toggle flips between `SecureField` and `TextField`.
- "Get a [Provider] key →" Link below each field; opens the official console.
- Soft prefix-mismatch warning ("Expected prefix sk-ant-") shown below the field when the trimmed value is non-empty and doesn't start with the expected prefix.
- "Saved" / "Unsaved" capsule shows next to the field, driven by `vm.isPersisted(_:)`. Empty fields show neither.

- [ ] **Step 2: Build and run all tests**

Run: `xcodebuild -scheme voxline -destination 'platform=macOS' test 2>&1 | tail -40`
Expected: PASS — pure View change, behavior tested in Tasks 1/4.

- [ ] **Step 3: Manual verification (skipped per project convention)**

(Defer manual verification to the controller after all tasks land. The visual behaviors — reveal toggle flips fields, links open in browser, prefix warning shows for wrong-format keys, Saved/Unsaved pill updates after blur — should be eyeballed once across both providers.)

- [ ] **Step 4: Commit**

```bash
git add voxline/Settings/APIKeysSettingsView.swift
git commit -m "api keys: reveal toggle, get-key links, prefix warning, Saved/Unsaved pill"
```

---

## Self-Review Checklist (run before handing off)

**Spec coverage:** Every issue from the review (#1–#21) maps to a task:
- #1 (testConnection silent save) → Task 1 (testConnection no longer saves) + Task 3 (save-on-blur happens at the natural point instead)
- #2, #3 (stale testResult / lastError) → Task 1 (auto-clear on key edit)
- #4 (whitespace) → Task 1 (trim on commit)
- #5 (Preview hits real keychain) → Task 1 (Preview removed)
- #6 (prefix validation) → Task 5 (soft warning)
- #7 (race during testing) → unchanged; benign
- #8 (VM not injected) → Task 1
- #9 (dead throws / saveWithErrorBanner) → Task 1 (per-key commit, no throws)
- #10 (activeKey in View) → resolved in Task 1 (provider gone from view)
- #11 (no testConnection coverage) → Task 4
- #12 (testConnection's save side-effect comment) → Task 1 (side-effect removed)
- #13 (Save button) → Task 3 (save-on-blur)
- #14 (no reveal toggle) → Task 5
- #15 (provider on wrong tab) → Task 2
- #16 (one Test button) → Task 1 (per-provider Test buttons land in the minimal-View update)
- #17 (no help links) → Task 5
- #18 (no Saved indicator) → Task 5 (Saved/Unsaved pill)
- #19 (no Remove key) → covered implicitly; empty + blur deletes, pill makes it visible
- #20 (Section labels) → unchanged; section structure preserves clarity
- #21 (.segmented Picker) → no issue

**Type consistency:**
- `APIKeyTestResult` redefined in Task 1 with associated provider; used identically in Tasks 1, 3, 4, 5. ✓
- `testing: LLMProvider?` introduced in Task 1, used in Tasks 1, 3, 5 with the same semantics. ✓
- `LLMClientFactory` typealias defined in Task 1, consumed in Task 4 tests. ✓
- `vm.isPersisted(_:)` defined in Task 1 VM, called in Task 5 View. ✓
- `provider` property on `GeneralSettingsViewModel` added in Task 2, with corresponding `Snapshot.provider` in same task. ✓

**Placeholders:** none. Every code step has the exact code.

**Risk callouts:**
- `@FocusState`'s `.onChange` semantics rely on iOS 17+/macOS 14+ two-arg closure (`{ previous, _ in }`). The project's deployment target should already meet this since the codebase uses `@Observable`. If a build error surfaces, fall back to the single-arg form and store the previous value in a separate `@State`.
- `.onDisappear` on the Form fires when the Settings window closes. If a user has a field focused and closes the window via Cmd-Q (app quit), `.onDisappear` may not fire reliably — accept that edge case; the next launch reads the keychain and shows the persisted value.
- `vm.isPersisted(_:)` reads keychain on every render. For two providers this is two keychain calls per render — fast but not free. If profiling shows it as hot, cache the persisted value on commit and invalidate on key change.
- Provider relocation (Task 2) means `AppSettings.llmProvider`'s setter currently clears `llmModel` (AppSettings.swift:35-38). With instant-apply on the General tab, *every* provider change triggers a model-default reset. This is desirable (a model id from one provider isn't valid for another) — the existing setter contract is preserved end-to-end.
