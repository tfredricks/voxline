# Settings Pages Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split the single long Settings page into six sidebar pages (General, Dictation, AI Provider, Commands, Vocabulary, Meetings) in the main window, with readiness marks, a Home "Setup" section, and the layout bugs fixed.

**Architecture:** `MainWindowPage` grows one case per settings page, and `MainWindowView` builds a sidebar with a "Settings" section. A `SettingsModel`, built once per window build, owns every settings view model, so page switches keep state. Each page is a small `Form` view in `voxline/Settings/Pages/`. `SettingsStatusViewModel` turns readiness into `[SetupIssue]`, which drives the sidebar marks and Home's Setup rows. The old `SettingsView`, its status strip and three section components are deleted.

**Tech Stack:** Swift 6, SwiftUI + AppKit, Swift Testing, Xcode 26, macOS 26.

**Spec:** `docs/superpowers/specs/2026-10-09-settings-pages-design.md`

## Global Constraints

- macOS 26 / Xcode 26. The Xcode project uses file-system synchronized folders: new files under `voxline/` or `voxlineTests/` need **no** `project.pbxproj` edits.
- Tests use Swift Testing (`import Testing`, `@Suite`, `@Test`, `#expect`). Run one suite with:
  `xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/<SuiteName> 2>&1 | tail -30`
  Run the full suite with the same command without `-only-testing`.
- Commits: Conventional Commits (`feat(settings): …`, `refactor(settings): …`, `docs(settings): …`), always `git commit -s` (DCO). End each message with a `Co-Authored-By:` line naming your model.
- No comments that narrate what code does. `///` doc comments only on types and behavior contracts.
- Field text never goes to logs.
- Copy (user-visible strings) is exact as written in this plan.
- Page titles: Home, General, Dictation, AI Provider, Commands, Vocabulary, Meetings. Sidebar symbols: `house`, `gearshape`, `mic`, `sparkles`, `command`, `character.book.closed`, `person.2`.
- Every settings page uses the `SettingsPage` wrapper (grouped `Form` + `navigationTitle`). No `.frame(maxWidth:)` caps and no `.scrollContentBackground(.hidden)` on pages.

## File map

| File | Task | Change |
|---|---|---|
| `voxline/UI/MainWindowController.swift` | 1, 5 | `MainWindowPage` cases, titles, symbols; `MainWindowView` rewritten in 5 |
| `voxline/Settings/SetupIssue.swift` | 1 | new |
| `voxline/Settings/SettingsStatusViewModel.swift` | 1, 5 | `issues`, `needsSetup`; chip properties removed in 5 |
| `voxline/Settings/Pages/SettingsPage.swift` | 1 | new wrapper |
| `voxline/Settings/Components/APIKeyRow.swift` | 2 | rows, not a `Section`; commit on disappear |
| `voxline/Settings/Components/LearningSection.swift` | 2 | notes become growing `TextField`s |
| `voxline/Settings/ChordRecorderView.swift`, `Components/KeyComboRecorderView.swift` | 2 | drop `.monospaced()` |
| `voxline/Settings/Pages/{General,Dictation,AIProvider}SettingsPage.swift` | 3 | new |
| `voxline/Settings/Pages/{Commands,Vocabulary,Meetings}SettingsPage.swift` | 4 | new |
| `voxline/Settings/SettingsModel.swift` | 5 | new |
| `voxline/UI/HomeView.swift` | 5 | Setup section |
| `voxline/voxlineApp.swift`, `voxline/MenuBar/MenuBarContent.swift` | 5 | wiring; Settings… opens `.general` |
| `SettingsView.swift`, `SettingsStatusStrip.swift`, `CleanupSection.swift`, `CommandSection.swift`, `MeetingsSection.swift` | 5 | deleted |
| user-facing "Settings → …" strings, docs | 6 | updated |

Execution waves (tasks in one wave touch disjoint files): **Wave 1:** Tasks 1, 2, 6. **Wave 2:** Tasks 3, 4 (need Task 1's `SettingsPage` and Task 2's `APIKeyRow`). **Wave 3:** Task 5.

---

### Task 1: Page model, setup issues, and the page wrapper

**Files:**
- Modify: `voxline/UI/MainWindowController.swift` (the `MainWindowPage` enum and the `MainWindowView` detail switch only)
- Create: `voxline/Settings/SetupIssue.swift`
- Modify: `voxline/Settings/SettingsStatusViewModel.swift`
- Create: `voxline/Settings/Pages/SettingsPage.swift`
- Create: `voxlineTests/MainWindowPageTests.swift`
- Modify: `voxlineTests/SettingsStatusViewModelTests.swift` (add tests; do not remove any yet)

**Interfaces:**
- Produces: `MainWindowPage` cases `.home, .settings, .general, .dictation, .aiProvider, .commands, .vocabulary, .meetings` (`.settings` stays until Task 5 removes it); `MainWindowPage.settingsPages: [MainWindowPage]`; `MainWindowPage.title: String`; `MainWindowPage.systemImage: String`.
- Produces: `struct SetupIssue: Equatable, Identifiable { let text: String; let page: MainWindowPage; var id: String }`.
- Produces: `SettingsStatusViewModel.issues: [SetupIssue]`, `SettingsStatusViewModel.needsSetup(_ page: MainWindowPage) -> Bool`.
- Produces: `struct SettingsPage<Content: View>: View`, `init(_ page: MainWindowPage, @ViewBuilder content: () -> Content)`.

- [ ] **Step 1: Write the failing tests**

Create `voxlineTests/MainWindowPageTests.swift`:

```swift
import Testing
@testable import voxline

@Suite struct MainWindowPageTests {

    @Test func settings_pages_are_listed_in_sidebar_order() {
        #expect(MainWindowPage.settingsPages == [.general, .dictation, .aiProvider, .commands, .vocabulary, .meetings])
    }

    @Test func pages_have_their_titles() {
        let titles = ([.home] + MainWindowPage.settingsPages).map(\.title)
        #expect(titles == ["Home", "General", "Dictation", "AI Provider", "Commands", "Vocabulary", "Meetings"])
    }

    @Test func pages_have_their_symbols() {
        let symbols = ([.home] + MainWindowPage.settingsPages).map(\.systemImage)
        #expect(symbols == ["house", "gearshape", "mic", "sparkles", "command", "character.book.closed", "person.2"])
    }
}
```

Append these tests inside `SettingsStatusViewModelTests` (they use the suite's existing `makeFixtures`):

```swift
    @Test func no_issues_when_everything_is_ready() async throws {
        let f = try makeFixtures()
        await f.status.refreshEngineReadiness()
        #expect(f.status.issues.isEmpty)
    }

    @Test func unchecked_readiness_is_not_an_issue() async throws {
        let f = try makeFixtures(readiness: { _ in nil })
        await f.status.refreshEngineReadiness()
        #expect(f.status.issues.isEmpty)
    }

    @Test func missing_provider_key_is_an_ai_provider_issue() async throws {
        let f = try makeFixtures(provider: .openai, openaiKey: "")
        await f.status.refreshEngineReadiness()
        #expect(f.status.issues == [SetupIssue(text: "No OpenAI API key", page: .aiProvider)])
    }

    @Test func unavailable_engine_reason_is_a_dictation_issue() async throws {
        let reason = "Apple Speech doesn't support this Mac's language."
        let f = try makeFixtures(engine: .apple, readiness: { _ in .unavailable(reason) })
        await f.status.refreshEngineReadiness()
        #expect(f.status.issues == [SetupIssue(text: reason, page: .dictation)])
    }

    @Test func whisper_download_issue_names_the_model_and_size() async throws {
        let f = try makeFixtures(engine: .whisperKit, readiness: { _ in .needsPreparation(downloadMB: 466) })
        await f.status.refreshEngineReadiness()
        #expect(f.status.issues == [SetupIssue(text: "The Whisper model needs a one-time download (466 MB)", page: .dictation)])
    }

    @Test func download_issue_omits_an_unknown_size() async throws {
        let f = try makeFixtures(engine: .apple, readiness: { _ in .needsPreparation(downloadMB: nil) })
        await f.status.refreshEngineReadiness()
        #expect(f.status.issues == [SetupIssue(text: "Apple Speech needs a one-time download", page: .dictation)])
    }

    @Test func missing_microphone_is_a_dictation_issue() async throws {
        let f = try makeFixtures(deviceUID: "ghost-uid")
        await f.status.refreshEngineReadiness()
        #expect(f.status.issues == [SetupIssue(text: "Microphone not found", page: .dictation)])
    }

    @Test func needs_setup_maps_issues_to_their_pages() async throws {
        let f = try makeFixtures(provider: .openai, openaiKey: "")
        await f.status.refreshEngineReadiness()
        #expect(f.status.needsSetup(.aiProvider))
        #expect(!f.status.needsSetup(.dictation))
        #expect(!f.status.needsSetup(.home))
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test … -only-testing:voxlineTests/MainWindowPageTests -only-testing:voxlineTests/SettingsStatusViewModelTests`
Expected: build failure. `settingsPages`, `title`, `systemImage`, `SetupIssue`, `issues` and `needsSetup` don't exist.

- [ ] **Step 3: Implement**

In `voxline/UI/MainWindowController.swift`, replace the enum:

```swift
enum MainWindowPage: Hashable {
    case home, settings
    case general, dictation, aiProvider, commands, vocabulary, meetings

    static let settingsPages: [MainWindowPage] = [.general, .dictation, .aiProvider, .commands, .vocabulary, .meetings]

    var title: String {
        switch self {
        case .home: "Home"
        case .settings: "Settings"
        case .general: "General"
        case .dictation: "Dictation"
        case .aiProvider: "AI Provider"
        case .commands: "Commands"
        case .vocabulary: "Vocabulary"
        case .meetings: "Meetings"
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house"
        case .settings, .general: "gearshape"
        case .dictation: "mic"
        case .aiProvider: "sparkles"
        case .commands: "command"
        case .vocabulary: "character.book.closed"
        case .meetings: "person.2"
        }
    }
}
```

In `MainWindowView.body`, change the detail switch so it still compiles (Task 5 replaces this view):

```swift
            switch selection.page ?? .home {
            case .home: home
            default: settings
            }
```

Create `voxline/Settings/SetupIssue.swift`:

```swift
import Foundation

/// Something that stops dictation or cleanup from working, and the settings
/// page that fixes it. Drives the sidebar marks and Home's Setup rows.
struct SetupIssue: Equatable, Identifiable {
    let text: String
    let page: MainWindowPage
    var id: String { text }
}
```

In `voxline/Settings/SettingsStatusViewModel.swift`, add after `providerChipText`:

```swift
    /// Unchecked readiness (nil) is not an issue, so opening the window
    /// doesn't flash a warning before the check finishes.
    var issues: [SetupIssue] {
        var result: [SetupIssue] = []
        if !micPresent {
            result.append(SetupIssue(text: "Microphone not found", page: .dictation))
        }
        switch currentReadiness {
        case .unavailable(let reason):
            result.append(SetupIssue(text: reason, page: .dictation))
        case .needsPreparation(let downloadMB):
            let name = general.engine == .whisperKit ? "The Whisper model" : general.engine.shortName
            let size = downloadMB.map { " (\($0) MB)" } ?? ""
            result.append(SetupIssue(text: "\(name) needs a one-time download\(size)", page: .dictation))
        case .ready, nil:
            break
        }
        if !providerKeySaved {
            result.append(SetupIssue(text: "No \(general.provider.displayName) API key", page: .aiProvider))
        }
        return result
    }

    func needsSetup(_ page: MainWindowPage) -> Bool {
        issues.contains { $0.page == page }
    }
```

Create `voxline/Settings/Pages/SettingsPage.swift`:

```swift
import SwiftUI

/// The frame every settings page shares: a grouped form that fills the
/// detail column, titled with the page's name.
struct SettingsPage<Content: View>: View {
    let page: MainWindowPage
    @ViewBuilder let content: Content

    init(_ page: MainWindowPage, @ViewBuilder content: () -> Content) {
        self.page = page
        self.content = content()
    }

    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .navigationTitle(page.title)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: the same command as Step 2.
Expected: PASS, with all old `SettingsStatusViewModelTests` still passing.

- [ ] **Step 5: Commit**

```bash
git add voxline/UI/MainWindowController.swift voxline/Settings/SetupIssue.swift voxline/Settings/SettingsStatusViewModel.swift voxline/Settings/Pages/SettingsPage.swift voxlineTests/MainWindowPageTests.swift voxlineTests/SettingsStatusViewModelTests.swift
git commit -s -m "feat(settings): settings page model, setup issues and page wrapper"
```

---

### Task 2: Component fixes (key rows, style notes, hotkey font)

These are SwiftUI view changes with no unit-testable logic. Verify them with a build and the existing suites.

**Files:**
- Modify: `voxline/Settings/Components/APIKeyRow.swift`
- Modify: `voxline/Settings/Components/CleanupSection.swift`
- Modify: `voxline/Settings/SettingsView.swift` (one call site; deleted in Task 5)
- Modify: `voxline/Settings/Components/LearningSection.swift`
- Modify: `voxline/Settings/ChordRecorderView.swift`
- Modify: `voxline/Settings/Components/KeyComboRecorderView.swift`

**Interfaces:**
- Produces: `APIKeyRow`, with an unchanged initializer, now emits form rows with no enclosing `Section`, so callers wrap it in a `Section`. It commits on disappear as well as on focus loss. `OpenAIKeyRow` is unchanged and inherits this.

- [ ] **Step 1: `APIKeyRow` emits rows**

In `APIKeyRow.body`:
- Remove the `Section(title) { … }` wrapper, so the body is the four row groups in sequence.
- Move the trailing `.onChange(of: focused) { _, isFocused in if !isFocused { onCommit() } }` off the removed section and onto the **first** `HStack` (the one holding the key field).
- Add `.onDisappear { onCommit() }` to the same `HStack`.

The result should be:

```swift
    var body: some View {
        HStack {
            Group {
                if revealed {
                    TextField("API key", text: $key)
                } else {
                    SecureField("API key", text: $key)
                }
            }
            .textContentType(.password)
            .focused($focused)
            .onSubmit(onCommit)

            Button {
                revealed.toggle()
            } label: {
                Image(systemName: revealed ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
            .help(revealed ? "Hide key" : "Reveal key")

            saveAffordance
        }
        .onChange(of: focused) { _, isFocused in
            if !isFocused { onCommit() }
        }
        .onDisappear { onCommit() }

        HStack(spacing: 8) {
            // … unchanged "Get a … key" link and prefix warning …
        }

        HStack {
            // … unchanged Test button, its comment, progress and result …
        }

        if let err = lastError {
            Text(err).foregroundStyle(.red).font(.callout)
        }
    }
```

Mark `body` with `@ViewBuilder`: `@ViewBuilder var body: some View {`.

- [ ] **Step 2: Wrap the existing call sites**

In `CleanupSection.body`, wrap the key row:

```swift
        Section("\(general.provider.displayName) API key") {
            keyRow(for: general.provider)
                .id(general.provider)
        }
        .onChange(of: general.provider) { _, _ in revealed = false }
```

Keep the existing multi-line comment above it.

In `SettingsView.swift`, wrap the recognition key row:

```swift
                    if generalVM.showsOpenAIKeyInRecognition {
                        Section("OpenAI API key") {
                            OpenAIKeyRow(general: generalVM, keys: apiKeysVM, revealed: $recognitionKeyRevealed)
                        }
                    }
```

- [ ] **Step 3: Style notes grow instead of scrolling**

In `LearningSection`, replace

```swift
                        TextEditor(text: noteBinding(category))
                            .font(.callout)
                            .frame(minHeight: 60)
```

with

```swift
                        TextField("Style note", text: noteBinding(category), axis: .vertical)
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(3...10)
                            .font(.callout)
```

- [ ] **Step 4: Proportional hotkey names**

- In `ChordRecorderView`, delete the `.monospaced()` line under `Text(chord.displayName)`.
- In `KeyComboRecorderView`, delete the `.monospaced()` line under the `Text(isRecording ? … )`.

- [ ] **Step 5: Build and run the related suites**

Run: `xcodebuild test … -only-testing:voxlineTests/APIKeysSettingsViewModelTests -only-testing:voxlineTests/LearningSettingsViewModelTests -only-testing:voxlineTests/SettingsStatusViewModelTests`
Expected: BUILD SUCCEEDED, tests PASS.

- [ ] **Step 6: Commit**

```bash
git add voxline/Settings
git commit -s -m "fix(settings): key rows join their section, style notes stop nested scrolling, proportional hotkey names"
```

---

### Task 3: General, Dictation and AI Provider pages

These are view-only files; verify them with a build. They are not yet shown (Task 5 wires them in).

**Files:**
- Create: `voxline/Settings/Pages/GeneralSettingsPage.swift`
- Create: `voxline/Settings/Pages/DictationSettingsPage.swift`
- Create: `voxline/Settings/Pages/AIProviderSettingsPage.swift`

**Interfaces:**
- Consumes: `SettingsPage(_:content:)` and `MainWindowPage` (Task 1); `APIKeyRow` and `OpenAIKeyRow` as rows (Task 2); the existing `GeneralSettingsViewModel`, `APIKeysSettingsViewModel`, `ChordRecorderView`, `MicLevelMeter`/`MicLevelMonitor`, `UpdateService` and `AppState`.
- Produces: `GeneralSettingsPage(general: GeneralSettingsViewModel)`, `DictationSettingsPage(general: GeneralSettingsViewModel, keys: APIKeysSettingsViewModel)`, `AIProviderSettingsPage(general: GeneralSettingsViewModel, keys: APIKeysSettingsViewModel)`. These need `AppState` and `UpdateService` in the environment.

- [ ] **Step 1: General page**

```swift
import AppKit
import SwiftUI

struct GeneralSettingsPage: View {
    @Bindable var general: GeneralSettingsViewModel
    @Environment(UpdateService.self) private var updateService
    @State private var confirmingReset = false

    var body: some View {
        @Bindable var updateService = updateService
        SettingsPage(.general) {
            Section("Startup") {
                Toggle("Launch Voxline at login", isOn: $general.launchAtLogin)
                if general.loginItemStatus == .requiresApproval {
                    Button {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        Label(
                            "Approval required — open Login Items in System Settings",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.callout)
                        .foregroundStyle(.orange)
                    }
                    .buttonStyle(.link)
                }
                Toggle("Show Voxline in Dock", isOn: $general.showInDock)
                Text("When off, Voxline appears in the Dock only while its window is open.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Updates") {
                Toggle("Automatically check for updates", isOn: $updateService.automaticallyChecksForUpdates)
                Text("Voxline checks once a day and shows a badge on the menu-bar icon when an update is ready.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Sounds") {
                Toggle("Play sound on record start/stop", isOn: $general.playHotkeySounds)
            }

            Section {
                HStack {
                    Spacer()
                    Button("Reset to Defaults…") { confirmingReset = true }
                }
            }
        }
        .confirmationDialog("Reset settings to defaults?", isPresented: $confirmingReset) {
            Button("Reset", role: .destructive) { general.resetToDefaults() }
        } message: {
            Text("Hotkeys, microphone, recognition, AI provider, command model and sounds go back to their defaults. API keys, presets, vocabulary, learning and meeting settings stay.")
        }
    }
}
```

- [ ] **Step 2: Dictation page**

```swift
import SwiftUI

struct DictationSettingsPage: View {
    @Environment(AppState.self) private var appState
    @Bindable var general: GeneralSettingsViewModel
    @Bindable var keys: APIKeysSettingsViewModel
    @State private var levelMonitor = MicLevelMonitor()
    @State private var keyRevealed = false

    var body: some View {
        SettingsPage(.dictation) {
            Section("Hotkey") {
                ChordRecorderView(
                    chord: $general.chord,
                    title: "Dictation",
                    validate: general.validateDictationChord
                )
                Text("Hold to dictate; release to insert the cleaned-up text.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Microphone") {
                Picker("Input device", selection: $general.audioInputDeviceUID) {
                    ForEach(general.deviceRows) { row in
                        Text(row.label).tag(row.uid)
                    }
                }
                HStack(spacing: 6) {
                    Text("Live level")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                    MicLevelMeter(monitor: levelMonitor)
                }
            }

            Section("Recognition") {
                Picker("Engine", selection: $general.engine) {
                    ForEach(EngineID.allCases, id: \.self) { e in
                        Text(e.displayName).tag(e)
                    }
                }
                switch general.engine {
                case .whisperKit:
                    Picker("Whisper model", selection: $general.whisperModel) {
                        ForEach(WhisperModel.allCases, id: \.self) { m in
                            let cached = TranscriptionService.isModelCached(m)
                            let label = cached
                                ? "\(m.displayName) — ✓ downloaded"
                                : "\(m.displayName) — to download · \(m.approxSizeMB) MB"
                            Text(label).tag(m)
                        }
                    }
                    Text("Switching downloads the new model on demand.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                case .openAIRealtime:
                    Text("Audio is sent to OpenAI and transcribed with your OpenAI API key.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                    if let warning = general.openAIKeyWarning {
                        Text(warning)
                            .foregroundStyle(.orange)
                            .font(.callout)
                    }
                case .apple:
                    EmptyView()
                }
                if general.showsOpenAIKeyInRecognition {
                    OpenAIKeyRow(general: general, keys: keys, revealed: $keyRevealed)
                }
            }
        }
        .onAppear {
            levelMonitor.preferredInputDeviceUID = general.audioInputDeviceUID
            startMonitorIfAllowed()
        }
        .onDisappear { levelMonitor.stop() }
        .onChange(of: general.audioInputDeviceUID) { _, newValue in
            levelMonitor.stop()
            levelMonitor.preferredInputDeviceUID = newValue
            startMonitorIfAllowed()
        }
        .onChange(of: appState.status) { _, newStatus in
            if newStatus == .recording {
                levelMonitor.stop()
            } else {
                startMonitorIfAllowed()
            }
        }
    }

    private func startMonitorIfAllowed() {
        guard appState.status != .recording else { return }
        try? levelMonitor.start()
    }
}
```

- [ ] **Step 3: AI Provider page**

```swift
import SwiftUI

struct AIProviderSettingsPage: View {
    @Bindable var general: GeneralSettingsViewModel
    @Bindable var keys: APIKeysSettingsViewModel
    @State private var revealed = false

    var body: some View {
        SettingsPage(.aiProvider) {
            Section("Provider") {
                Picker("Provider", selection: $general.provider) {
                    ForEach(LLMProvider.allCases, id: \.self) { p in
                        Text(p.displayName).tag(p)
                    }
                }
                .pickerStyle(.segmented)
                Text("Cleans up dictation, runs commands and writes meeting notes.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            // Rebuilt per provider so one provider's editor state can't show
            // under the other; reveal resets so switching never shows a key.
            Section("\(general.provider.displayName) API key") {
                keyRow(for: general.provider)
                    .id(general.provider)
            }
        }
        .onChange(of: general.provider) { _, _ in revealed = false }
    }

    @ViewBuilder
    private func keyRow(for provider: LLMProvider) -> some View {
        switch provider {
        case .anthropic:
            APIKeyRow(
                title: "Anthropic",
                provider: .anthropic,
                key: $keys.anthropicKey,
                revealed: $revealed,
                getKeyURL: URL(string: "https://console.anthropic.com/settings/keys")!,
                expectedPrefix: "sk-ant-",
                isPersisted: keys.isPersisted(.anthropic),
                testing: keys.testing,
                testResult: keys.testResult,
                lastError: keys.lastError,
                onCommit: { keys.commitAnthropic() },
                onTest: { Task { await keys.testConnection(.anthropic) } }
            )
        case .openai:
            OpenAIKeyRow(general: general, keys: keys, revealed: $revealed)
        }
    }
}
```

- [ ] **Step 4: Build**

Run: `xcodebuild build -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' 2>&1 | tail -5`
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add voxline/Settings/Pages
git commit -s -m "feat(settings): General, Dictation and AI Provider pages"
```

---

### Task 4: Commands, Vocabulary and Meetings pages

These are view-only files; verify them with a build.

**Files:**
- Create: `voxline/Settings/Pages/CommandsSettingsPage.swift`
- Create: `voxline/Settings/Pages/VocabularySettingsPage.swift`
- Create: `voxline/Settings/Pages/MeetingsSettingsPage.swift`

**Interfaces:**
- Consumes: `SettingsPage(_:content:)` (Task 1); `LearningSection` with growing notes (Task 2); the existing `CommandSettingsViewModel`, `CustomVocabularyListView`/`CustomVocabularyListViewModel`, `LearningSettingsViewModel`, `MeetingSettingsViewModel`, `KeyComboRecorderView`, `ChordRecorderView` and `PresetShortcut`.
- Produces: `CommandsSettingsPage(general: GeneralSettingsViewModel, command: CommandSettingsViewModel)`, `VocabularySettingsPage(vocabulary: CustomVocabularyListViewModel, learning: LearningSettingsViewModel)`, `MeetingsSettingsPage(model: MeetingSettingsViewModel)`.

- [ ] **Step 1: Commands page**

`PresetRow` and `CommittingTextField` are copied here from `CommandSection.swift`, which Task 5 deletes. They stay `private`, so both copies compile until then.

```swift
import SwiftUI

struct CommandsSettingsPage: View {
    @Bindable var general: GeneralSettingsViewModel
    let command: CommandSettingsViewModel

    var body: some View {
        SettingsPage(.commands) {
            Section {
                Toggle("Command mode", isOn: $general.commandModeEnabled)
                if general.commandModeEnabled {
                    ChordRecorderView(
                        chord: Binding(
                            get: { general.commandChord ?? .defaultCommand },
                            set: { general.commandChord = $0 }
                        ),
                        title: "Hotkey",
                        validate: general.validateCommandChord
                    )
                }
                Text("Hold to speak an edit: rewrite the selection, draft a reply, or change part of the field.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }

            Section("Model") {
                TextField("Command model", text: $general.commandModel, prompt: Text(general.cleanupModelPlaceholder))
                Text("Leave empty to use the cleanup model. A larger model drafts and answers better but responds more slowly.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }

            Section("Presets") {
                ForEach(command.presets) { preset in
                    PresetRow(preset: preset, model: command)
                }
                HStack {
                    Button("Add preset") { command.addPreset() }
                    Button("Restore default presets") { command.restoreDefaults() }
                }
                Text("Preset shortcuts work everywhere and are captured even with nothing selected. ⌥1 ⌥2 ⌥3 normally type ¡ ™ £ — remap them if you use those characters.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
        }
    }
}
```

Then copy `private struct PresetRow` and `private struct CommittingTextField` from `voxline/Settings/Components/CommandSection.swift` verbatim, including `CommittingTextField`'s `///` doc comment, to the end of this file.

- [ ] **Step 2: Vocabulary page**

```swift
import SwiftUI

struct VocabularySettingsPage: View {
    let vocabulary: CustomVocabularyListViewModel
    let learning: LearningSettingsViewModel

    var body: some View {
        SettingsPage(.vocabulary) {
            CustomVocabularyListView(viewModel: vocabulary)
            LearningSection(model: learning)
        }
    }
}
```

- [ ] **Step 3: Meetings page**

```swift
import AppKit
import SwiftUI

struct MeetingsSettingsPage: View {
    @Bindable var model: MeetingSettingsViewModel

    var body: some View {
        SettingsPage(.meetings) {
            Section("Recording") {
                LabeledContent("Start/stop shortcut") {
                    HStack(spacing: 8) {
                        KeyComboRecorderView(combo: model.shortcut, onRecord: { model.updateShortcut($0) })
                        if model.shortcut != nil {
                            Button("Clear") { model.clearShortcut() }
                        }
                    }
                }
                Toggle("Show recording timer", isOn: $model.showTimer)
                Picker("Keep meeting audio", selection: $model.retention) {
                    ForEach(MeetingAudioRetention.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Text("Meetings record your microphone and your Mac's sound output for up to 60 minutes. Audio stays on this Mac; only the transcript goes to your LLM provider to write the notes. Use headphones on calls for the cleanest transcript.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Notes") {
                LabeledContent("Notes folder") {
                    HStack(spacing: 8) {
                        Text(model.notesFolder.path(percentEncoded: false))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Choose…") { chooseFolder() }
                    }
                }
                TextField("Meeting notes model", text: $model.notesModel, prompt: Text(model.notesModelPlaceholder))
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = model.notesFolder
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            model.setNotesFolder(url)
        }
    }
}
```

- [ ] **Step 4: Build**

Run: `xcodebuild build -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' 2>&1 | tail -5`
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add voxline/Settings/Pages
git commit -s -m "feat(settings): Commands, Vocabulary and Meetings pages"
```

---

### Task 5: Wire the pages into the window; remove the old Settings

**Files:**
- Create: `voxline/Settings/SettingsModel.swift`
- Create: `voxlineTests/SettingsModelTests.swift`
- Modify: `voxline/UI/MainWindowController.swift` (remove `.settings`; rewrite `MainWindowView`)
- Modify: `voxline/UI/HomeView.swift`
- Modify: `voxline/voxlineApp.swift`
- Modify: `voxline/MenuBar/MenuBarContent.swift`
- Modify: `voxline/Settings/SettingsStatusViewModel.swift` (remove the chip properties, `isReady` and `engineUnavailableReason`)
- Modify: `voxlineTests/SettingsStatusViewModelTests.swift`
- Modify: `voxlineTests/MainWindowControllerTests.swift`
- Delete: `voxline/Settings/SettingsView.swift`, `voxline/Settings/Components/SettingsStatusStrip.swift`, `voxline/Settings/Components/CleanupSection.swift`, `voxline/Settings/Components/CommandSection.swift`, `voxline/Settings/Components/MeetingsSection.swift`

**Interfaces:**
- Consumes: everything Tasks 1–4 produce.
- Produces: `SettingsModel` (the init below); `MainWindowView(selection: MainWindowSelection, home: HomeViewModel, settings: SettingsModel)`; `HomeView(model: HomeViewModel, issues: [SetupIssue], open: (MainWindowPage) -> Void)`.

- [ ] **Step 1: Write the failing tests**

Create `voxlineTests/SettingsModelTests.swift`. It builds `LearningCoordinator` with the same fakes as `LearningSettingsViewModelTests.makeHarness()`. The test checks that `refresh()` pulls in a value written to UserDefaults behind the view model's back:

```swift
import Foundation
import Testing
@testable import voxline

@Suite @MainActor struct SettingsModelTests {

    @Test func refresh_reloads_settings_changed_elsewhere() throws {
        let suiteName = "voxline-settings-model-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        let general = GeneralSettingsViewModel(
            settings: settings,
            onApply: { _ in },
            deviceEnumerator: { [] }
        )
        let learning = LearningCoordinator(
            state: AppState(),
            store: LearningStore(fileURL: nil, now: { Date() }),
            vocabulary: CustomVocabularyStore(defaults: defaults),
            reader: FakeCorrectionReader(anchors: [.skipped(.noElement)]),
            dictionary: FakeWordDictionary(),
            toggles: { LearningToggles(words: false, style: false) },
            generator: FakeStyleGenerator(),
            model: { "test-model" }
        )
        let model = SettingsModel(
            general: general,
            apiKeys: APIKeysSettingsViewModel(keychain: InMemoryKeychain()),
            command: CommandSettingsViewModel(chords: { general.chords }, onChange: {}),
            meetings: MeetingSettingsViewModel(settings: settings, presets: { [] }, chords: { general.chords }, onChange: {}),
            learning: learning,
            engineReadiness: { _ in .ready }
        )
        var elsewhere = AppSettings(defaults: defaults)
        elsewhere.playHotkeySounds = !general.playHotkeySounds
        let expected = elsewhere.playHotkeySounds

        model.refresh()

        #expect(model.general.playHotkeySounds == expected)
    }
}
```

In `voxlineTests/MainWindowControllerTests.swift`, replace the last test:

```swift
    @Test func show_general_selects_the_general_page() {
        let probe = ContentProbe()
        let controller = makeController(probe)
        defer { tearDown(controller) }

        controller.show(.general)

        #expect(probe.lastSelection?.page == .general)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test … -only-testing:voxlineTests/SettingsModelTests`
Expected: build failure, because `SettingsModel` doesn't exist.

- [ ] **Step 3: `SettingsModel`**

Create `voxline/Settings/SettingsModel.swift`:

```swift
import Foundation

/// Every settings view model, built once per main-window build and shared by
/// all the settings pages, so switching pages keeps unsaved state.
@MainActor
final class SettingsModel {
    let general: GeneralSettingsViewModel
    let apiKeys: APIKeysSettingsViewModel
    let command: CommandSettingsViewModel
    let meetings: MeetingSettingsViewModel
    let vocabulary: CustomVocabularyListViewModel
    let learningSettings: LearningSettingsViewModel
    let status: SettingsStatusViewModel
    let learning: LearningCoordinator

    init(
        general: GeneralSettingsViewModel,
        apiKeys: APIKeysSettingsViewModel,
        command: CommandSettingsViewModel,
        meetings: MeetingSettingsViewModel,
        learning: LearningCoordinator,
        engineReadiness: @escaping @MainActor (EngineID) async -> EngineReadiness?
    ) {
        self.general = general
        self.apiKeys = apiKeys
        self.command = command
        self.meetings = meetings
        self.learning = learning
        self.vocabulary = CustomVocabularyListViewModel(
            store: CustomVocabularyStore(),
            onRemoveLearned: { [weak learning] in learning?.learnedWordsRemoved($0) },
            onAdd: { [weak learning] in learning?.wordAddedByUser($0) }
        )
        self.learningSettings = LearningSettingsViewModel(learning: learning)
        self.status = SettingsStatusViewModel(general: general, keys: apiKeys, engineReadiness: engineReadiness)
    }

    func refresh() {
        general.refreshFromUserDefaults()
        general.refreshLoginItemStatus()
    }
}
```

- [ ] **Step 4: `MainWindowView`**

In `voxline/UI/MainWindowController.swift`:
- Remove `case settings` and its `title`/`systemImage` arms from `MainWindowPage` (`.general` keeps `gearshape`).
- Replace `struct MainWindowView` entirely:

```swift
struct MainWindowView: View {
    @Bindable var selection: MainWindowSelection
    let home: HomeViewModel
    let settings: SettingsModel
    @Environment(AppState.self) private var appState

    var body: some View {
        NavigationSplitView {
            List(selection: $selection.page) {
                sidebarRow(.home)
                Section("Settings") {
                    ForEach(MainWindowPage.settingsPages, id: \.self) { sidebarRow($0) }
                }
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
        } detail: {
            detail(for: selection.page ?? .home)
        }
        .task { settings.refresh() }
        .task(id: settings.status.readinessKey) {
            await settings.status.refreshEngineReadiness()
        }
        .onChange(of: settings.learning.vocabularyRevision) { _, _ in
            settings.vocabulary.reload()
        }
        .onChange(of: appState.status) { oldStatus, newStatus in
            if oldStatus.blocksRecording && !newStatus.blocksRecording {
                Task { await settings.status.refreshEngineReadiness() }
            }
        }
    }

    private func sidebarRow(_ page: MainWindowPage) -> some View {
        let issue = settings.status.issues.first { $0.page == page }
        return HStack {
            Label(page.title, systemImage: page.systemImage)
            if let issue {
                Spacer()
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
                    .help(issue.text)
                    .accessibilityLabel("Needs setup")
            }
        }
        .tag(page)
    }

    @ViewBuilder
    private func detail(for page: MainWindowPage) -> some View {
        switch page {
        case .home:
            HomeView(model: home, issues: settings.status.issues, open: { selection.page = $0 })
        case .general:
            GeneralSettingsPage(general: settings.general)
        case .dictation:
            DictationSettingsPage(general: settings.general, keys: settings.apiKeys)
        case .aiProvider:
            AIProviderSettingsPage(general: settings.general, keys: settings.apiKeys)
        case .commands:
            CommandsSettingsPage(general: settings.general, command: settings.command)
        case .vocabulary:
            VocabularySettingsPage(vocabulary: settings.vocabulary, learning: settings.learningSettings)
        case .meetings:
            MeetingsSettingsPage(model: settings.meetings)
        }
    }
}
```

Update the `MainWindowController` doc comment's "a sidebar with Home and Settings" to "a sidebar with Home and the settings pages".

- [ ] **Step 5: Home Setup section**

In `voxline/UI/HomeView.swift`, add the properties under `model`:

```swift
    let issues: [SetupIssue]
    let open: (MainWindowPage) -> Void
```

In `body`'s `Form`, insert between `Section { statusRow }` and `Section("Permissions")`:

```swift
            if !issues.isEmpty {
                Section("Setup") {
                    ForEach(issues) { issue in
                        HStack {
                            Label {
                                Text(issue.text)
                            } icon: {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .foregroundStyle(.orange)
                            }
                            Spacer()
                            Button("Open \(issue.page.title)") { open(issue.page) }
                        }
                    }
                }
            }
```

- [ ] **Step 6: App wiring**

In `voxline/voxlineApp.swift`:
- `CommandGroup(replacing: .appSettings)`: change `show(.settings)` to `show(.general)`.
- Replace the `mainWindow` closure and `makeSettingsView()` with:

```swift
    lazy var mainWindow = MainWindowController { [unowned self] selection in
        AnyView(
            MainWindowView(
                selection: selection,
                home: HomeViewModel(state: appState),
                settings: makeSettingsModel()
            )
            .environment(appState)
            .environment(updateService)
        )
    }

    private func makeSettingsModel() -> SettingsModel {
        let coordinator = self.coordinator
        let generalVM = GeneralSettingsViewModel(onApply: { [weak coordinator] snapshot in
            coordinator?.apply(snapshot)
        })
        return SettingsModel(
            general: generalVM,
            apiKeys: APIKeysSettingsViewModel(onOpenAIKeyChange: { [weak coordinator] in
                coordinator?.openAIKeyDidChange()
            }),
            command: CommandSettingsViewModel(
                chords: { [weak generalVM] in generalVM?.chords ?? AppSettings().chords },
                onChange: { [weak coordinator] in coordinator?.presetsDidChange() },
                reserved: { AppSettings().meetingShortcut.map { [$0] } ?? [] }
            ),
            meetings: MeetingSettingsViewModel(
                presets: { PresetStore().load() },
                chords: { [weak generalVM] in generalVM?.chords ?? AppSettings().chords },
                onChange: { [weak coordinator] in coordinator?.meetingSettingsDidChange() }
            ),
            learning: learning,
            engineReadiness: { [weak coordinator] id in
                await coordinator?.readiness(of: id)
            }
        )
    }
```

In `voxline/MenuBar/MenuBarContent.swift`, change `openMainWindow(.settings)` to `openMainWindow(.general)`.

- [ ] **Step 7: Delete the old Settings**

```bash
git rm voxline/Settings/SettingsView.swift voxline/Settings/Components/SettingsStatusStrip.swift voxline/Settings/Components/CleanupSection.swift voxline/Settings/Components/CommandSection.swift voxline/Settings/Components/MeetingsSection.swift
```

- [ ] **Step 8: Remove the strip-only status properties and rewrite their tests**

In `SettingsStatusViewModel`:
- Delete `isReady`, `engineChipShowsCheck`, `providerChipShowsCheck`, `micChipText`, `engineChipText`, `engineUnavailableReason`, `providerChipText` and the private `engineReady`.
- Update the type's doc comment to: "Derives the settings setup issues from the settings view models and the selected engine's readiness, which `refreshEngineReadiness()` fetches through the injected check."

In `SettingsStatusViewModelTests`, keep every test added in Task 1 and the readiness-key tests. Rewrite each remaining assertion on a removed property as an assertion on `issues`:
- `ready_when_provider_key_saved_and_engine_ready_and_mic_present`: delete it; Task 1's `no_issues_when_everything_is_ready` covers it.
- `setup_needed_until_readiness_is_checked`: delete it; it contradicts the spec, and `unchecked_readiness_is_not_an_issue` replaces it.
- `setup_needed_when_active_provider_key_missing`, `setup_needed_when_engine_needs_preparation`, `setup_needed_and_reason_shown_when_engine_unavailable`, `setup_needed_when_engines_are_not_built_yet`, `setup_needed_when_saved_mic_uid_is_disconnected`: delete them; Task 1's issue tests cover each.
- `setup_needed_when_no_devices_and_no_uid`: keep it, asserting `status.issues == [SetupIssue(text: "Microphone not found", page: .dictation)]`.
- `switching_engines_hides_the_check_until_rechecked`: use `readiness: { _ in .needsPreparation(downloadMB: nil) }` for the second engine. Assert the issue appears only after re-checking, or, simpler, make the test assert that `issues` is empty right after switching (unchecked) and non-empty after `refreshEngineReadiness()` returns `.needsPreparation`. Rename it `switching_engines_drops_the_old_check`.
- `switching_whisper_models_hides_the_check_until_rechecked`: same pattern; rename it `switching_whisper_models_drops_the_old_check`.
- `saving_an_openai_key_rechecks_the_openai_engine`:
  - Replace `engineChipShowsCheck == false` with `issues.contains { $0.page == .dictation }`.
  - Replace `engineUnavailableReason == nil` with `!issues.contains { $0.page == .dictation }` (the old check no longer matches the key).
  - Replace the final `engineChipShowsCheck == true` with `!issues.contains { $0.page == .dictation }`.
- `saving_an_openai_key_keeps_an_on_device_check`: keep the readiness-key assertion; replace the check assertion with `f.status.issues.isEmpty`.
- `a_superseded_check_does_not_overwrite_a_newer_one`: replace `engineChipShowsCheck == true` with `f.status.issues.isEmpty` (both places).
- `engine_chip_names_the_whisper_model_only_for_whisper` and `mic_chip_uses_selected_device_label`: delete them.

- [ ] **Step 9: Run the full suite**

Run: `xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' 2>&1 | tail -30`
Expected: TEST SUCCEEDED. Check with `grep -rn "SettingsView\b\|SettingsAnchor\|\.settings)" voxline voxlineTests` that there are no references to deleted types or to `.settings`.

- [ ] **Step 10: Commit**

```bash
git add -A voxline voxlineTests
git commit -s -m "feat(settings): show Settings as sidebar pages with setup marks; remove the single Settings page"
```

---

### Task 6: User-facing paths and docs

These are copy and doc edits only; they don't depend on Tasks 1–5 compiling.

**Files:**
- Modify: `voxline/Transcription/Engines/OpenAIRealtimeEngine.swift:55`
- Modify: `voxline/Pipeline/CapturePipeline.swift:476`
- Modify: `voxline/LLM/LLMProvider.swift:110`
- Modify: `voxline/Storage/KeychainStorage.swift:42`
- Modify: doc comments in `voxline/AppCoordinator.swift:456`, `voxline/Settings/CommandSettingsViewModel.swift:4`, `voxline/Settings/LearningSettingsViewModel.swift:4`, `voxline/Settings/GeneralSettingsViewModel.swift:235`, `voxline/Storage/AppSettings.swift:211,225`
- Modify: any test asserting the old strings (search with `grep -rn "Settings → General\|Settings → API Keys" voxlineTests`)
- Modify: `docs/release/MANUAL_TESTS.md`, `AGENTS.md`, `CHANGELOG.md`, `README.md` (only where it describes the Settings layout), `docs/superpowers/specs/2026-10-09-settings-pages-design.md` (Status line)

- [ ] **Step 1: User-facing strings** (exact new text)

| File | New string |
|---|---|
| `OpenAIRealtimeEngine.missingKeyReason` | `"Add an OpenAI API key in Settings → Dictation to use OpenAI transcription."` |
| `CapturePipeline.swift:476` | `"Transcription failed. Try again or pick a different engine in Settings → Dictation."` |
| `LLMProvider.swift:110` | `"No API key configured. Open Settings → AI Provider to set one."` |
| `KeychainStorage.swift:42` | `"The saved API key is in an unexpected format. Re-enter it in Settings → AI Provider."` |

Leave `CapturePipeline.swift:558` ("Settings → Modes") alone; it is out of scope.

- [ ] **Step 2: Doc comments**

Change these comments to the new page names:
- `Settings → Command` → `Settings → Commands`.
- `Settings → Learning` → `Settings → Vocabulary (Learning)`, in `LearningSettingsViewModel`, `GeneralSettingsViewModel.resetToDefaults`'s comment and both `AppSettings` comments.

- [ ] **Step 3: Update the tests that assert the old strings**

Run: `grep -rn "Settings → General\|Settings → API Keys\|General → Recognition" voxline voxlineTests`
Update each test hit to the new string. Expected: no hits remain in `voxline/`.

- [ ] **Step 4: Docs**

- **`AGENTS.md`:** in the `voxline/UI/MainWindowController.swift` bullet, replace "a sidebar with Home (…) and Settings (`SettingsView`)" with "a sidebar with Home (`HomeView`/`HomeViewModel`: status, setup issues, permissions, recent meetings) and six settings pages (`voxline/Settings/Pages/`: General, Dictation, AI Provider, Commands, Vocabulary, Meetings) that share one `SettingsModel` per window build". Keep the rest of the bullet.
- **`CHANGELOG.md`:** under the existing unreleased heading (create `## Unreleased` at the top if there is none, matching the file's style), add: "Settings is now six pages in the main window's sidebar — General, Dictation, AI Provider, Commands, Vocabulary, Meetings — with marks on pages that need setup and a Setup section on Home. Fixes the narrow Settings column and style notes that captured scrolling."
- **`docs/release/MANUAL_TESTS.md`:** in the "Main window and Dock icon" section, replace any item mentioning the Settings page or status strip with a "Settings pages" subsection listing:
  - each page fits at 720×480 and at full screen, with the scroll bar at the window edge;
  - scrolling over a style note on Vocabulary scrolls the page;
  - the mic-in-use indicator is on only on Dictation;
  - an API key typed and left by switching pages shows as Saved on return;
  - ⌘, opens General;
  - removing the API key shows an orange mark on AI Provider and a Setup row on Home, whose button opens AI Provider;
  - Reset to Defaults… asks before resetting.
- **`README.md`:** `grep -n -i "settings" README.md`. Update only sentences naming the old single-page layout or the status strip, to the new page names.
- **Spec:** change the `**Status:**` line to `Approved; implemented (see plan 2026-10-09-settings-pages.md).`

- [ ] **Step 5: Build and run the touched suites**

Run: `xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' 2>&1 | tail -15`
Expected: TEST SUCCEEDED.

- [ ] **Step 6: Commit**

```bash
git add -A voxline voxlineTests docs AGENTS.md CHANGELOG.md README.md
git commit -s -m "docs(settings): point messages and docs at the new settings pages"
```
