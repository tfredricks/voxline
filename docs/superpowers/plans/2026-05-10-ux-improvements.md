# UX Improvements Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Dock icon while user-facing windows are open, an About dialog with GitHub Issues links, and a Launch-at-Login toggle in Settings.

**Architecture:** Three independent, isolated components. `WindowVisibilityCoordinator` counts windows tagged with a known `NSUserInterfaceItemIdentifier` and flips `NSApp.activationPolicy` between `.accessory` and `.regular`. `AboutWindowController` hosts a SwiftUI `AboutView` driven by a pure-functions `SupportLinks` URL builder. `LoginItemService` wraps `SMAppService.mainApp` behind a protocol seam so it's testable; `GeneralSettingsViewModel` exposes a `launchAtLogin` toggle and `loginItemStatus` for an inline approval hint.

**Tech Stack:** SwiftUI + AppKit (`NSWindow`, `NSWorkspace`), `ServiceManagement.SMAppService`, swift-testing (`@Suite`/`@Test`/`#expect`), Xcode build via `xcodebuild`.

**Decisions baked in (from spec):**
- Inclusion-list tagging for dock-worthy windows (HUDs untagged, never trigger Dock).
- Custom SwiftUI About window (not `orderFrontStandardAboutPanel`).
- Bug + Feedback both go to GitHub Issues with separate templates.
- Inline approval hint for Launch at Login (no modal alert).

**Out of scope (deferred):**
- Status-aware menu header, Help submenu, quick mode switch, re-run Welcome, Sparkle updates.
- Anything that touches capture / transcription / LLM / output code paths.

---

## File Map

**New:**
- `voxline/Settings/SupportLinks.swift` — `SupportEnvironment` struct + `SupportLinks` URL builder
- `voxline/Settings/LoginItemService.swift` — `LoginItemService` + `LoginItemBackend` protocol
- `voxline/UI/AboutView.swift` — SwiftUI About content
- `voxline/UI/AboutWindowController.swift` — NSWindow host for `AboutView`
- `voxline/MenuBar/WindowVisibilityCoordinator.swift` — activation policy switcher
- `voxlineTests/SupportLinksTests.swift`
- `voxlineTests/LoginItemServiceTests.swift`
- `voxlineTests/WindowVisibilityCoordinatorTests.swift`
- `.github/ISSUE_TEMPLATE/bug.yml`
- `.github/ISSUE_TEMPLATE/feedback.yml`

**Modified:**
- `voxline/Settings/GeneralSettingsViewModel.swift` — add `launchAtLogin`, `loginItemStatus`, `loginItemService`, `refreshLoginItemStatus()`
- `voxline/Settings/SettingsView.swift` — add "Startup" section at top of Form
- `voxline/MenuBar/MenuBarContent.swift` — add "About voxline" button, take `openAboutWindow` + `tagSettingsWindow` closures
- `voxline/voxlineApp.swift` — instantiate coordinator + about controller, wire MenuBarContent
- `voxline/Wizard/FirstRunWindowController.swift` — tag wizard window as dockworthy
- `voxline/Debug/DebugView.swift` — tag debug window as dockworthy
- `voxlineTests/GeneralSettingsViewModelTests.swift` — add launch-at-login tests

---

## Task 1: SupportLinks (URL builder + SupportEnvironment)

Pure functions. No UI. Foundation only. TDD-friendly.

**Files:**
- Create: `voxline/Settings/SupportLinks.swift`
- Create: `voxlineTests/SupportLinksTests.swift`

- [ ] **Step 1: Write failing tests**

Create `voxlineTests/SupportLinksTests.swift`:

```swift
import Testing
import Foundation
@testable import voxline

@Suite struct SupportLinksTests {

    @Test func repo_url_is_canonical_https() {
        #expect(SupportLinks.repoURL.absoluteString == "https://github.com/tfredricks/voxline")
    }

    @Test func bug_report_url_uses_bug_template_and_encodes_body() {
        let env = SupportEnvironment(
            appVersion: "1.0",
            buildNumber: "1",
            osVersion: "Version 14.5 (Build 23F79)",
            whisperModel: "large-v3-turbo",
            micDevice: "MacBook Pro Microphone"
        )
        let url = SupportLinks.bugReportURL(env: env)
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        #expect(components.host == "github.com")
        #expect(components.path == "/tfredricks/voxline/issues/new")
        let query = components.queryItems ?? []
        #expect(query.contains(URLQueryItem(name: "template", value: "bug.yml")))
        let body = query.first { $0.name == "body" }?.value ?? ""
        #expect(body.contains("voxline version: 1.0 (1)"))
        #expect(body.contains("macOS: Version 14.5 (Build 23F79)"))
        #expect(body.contains("Whisper model: large-v3-turbo"))
        #expect(body.contains("Mic device: MacBook Pro Microphone"))
    }

    @Test func bug_report_url_falls_back_to_system_default_for_missing_mic() {
        let env = SupportEnvironment(
            appVersion: "1.0", buildNumber: "1",
            osVersion: "14.5", whisperModel: "tiny", micDevice: nil
        )
        let url = SupportLinks.bugReportURL(env: env)
        let body = (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .first { $0.name == "body" }?.value ?? ""
        #expect(body.contains("Mic device: (system default)"))
    }

    @Test func feedback_url_uses_feedback_template() {
        let env = SupportEnvironment(
            appVersion: "1.0", buildNumber: "1",
            osVersion: "14.5", whisperModel: "tiny", micDevice: nil
        )
        let url = SupportLinks.feedbackURL(env: env)
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(q.contains(URLQueryItem(name: "template", value: "feedback.yml")))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme voxline -destination 'platform=macOS' test -only-testing:voxlineTests/SupportLinksTests 2>&1 | tail -30`
Expected: build error — `SupportLinks` and `SupportEnvironment` not defined.

- [ ] **Step 3: Implement SupportLinks**

Create `voxline/Settings/SupportLinks.swift`:

```swift
import Foundation

struct SupportEnvironment: Equatable {
    let appVersion: String
    let buildNumber: String
    let osVersion: String
    let whisperModel: String
    let micDevice: String?

    var bodyMarkdown: String {
        """
        **Environment**
        - voxline version: \(appVersion) (\(buildNumber))
        - macOS: \(osVersion)
        - Whisper model: \(whisperModel)
        - Mic device: \(micDevice ?? "(system default)")
        """
    }

    static func current(whisperModel: String, micDevice: String?) -> SupportEnvironment {
        let info = Bundle.main.infoDictionary ?? [:]
        let appVersion = (info["CFBundleShortVersionString"] as? String) ?? "?"
        let buildNumber = (info["CFBundleVersion"] as? String) ?? "?"
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        return SupportEnvironment(
            appVersion: appVersion,
            buildNumber: buildNumber,
            osVersion: osVersion,
            whisperModel: whisperModel,
            micDevice: micDevice
        )
    }
}

enum SupportLinks {
    static let repoURL = URL(string: "https://github.com/tfredricks/voxline")!

    static func bugReportURL(env: SupportEnvironment) -> URL {
        issueURL(template: "bug.yml", body: env.bodyMarkdown)
    }

    static func feedbackURL(env: SupportEnvironment) -> URL {
        issueURL(template: "feedback.yml", body: env.bodyMarkdown)
    }

    private static func issueURL(template: String, body: String) -> URL {
        var components = URLComponents(string: "https://github.com/tfredricks/voxline/issues/new")!
        components.queryItems = [
            URLQueryItem(name: "template", value: template),
            URLQueryItem(name: "body", value: body),
        ]
        return components.url!
    }
}
```

Add the new file to the Xcode project (`voxline.xcodeproj`) target `voxline` and the test file to target `voxlineTests`. (In Xcode: drag into the Project Navigator under the matching group; ensure target membership is correct.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild -scheme voxline -destination 'platform=macOS' test -only-testing:voxlineTests/SupportLinksTests 2>&1 | tail -30`
Expected: PASS — 4 tests.

- [ ] **Step 5: Commit**

```bash
git add voxline/Settings/SupportLinks.swift voxlineTests/SupportLinksTests.swift voxline.xcodeproj
git commit -m "feat(support): SupportLinks + SupportEnvironment for GitHub Issues URLs"
```

---

## Task 2: GitHub Issue templates

Plain YAML files. No tests; verified manually by clicking the buttons after Task 6.

**Files:**
- Create: `.github/ISSUE_TEMPLATE/bug.yml`
- Create: `.github/ISSUE_TEMPLATE/feedback.yml`

- [ ] **Step 1: Create bug template**

Create `.github/ISSUE_TEMPLATE/bug.yml`:

```yaml
name: Bug report
description: Something in voxline isn't working
title: "Bug: "
labels: ["bug"]
body:
  - type: textarea
    id: details
    attributes:
      label: What happened?
      description: Steps to reproduce, expected vs. actual behavior, and any environment info auto-filled below.
      placeholder: |
        1. Open voxline
        2. ...
        3. Expected: ... Actual: ...
    validations:
      required: true
```

- [ ] **Step 2: Create feedback template**

Create `.github/ISSUE_TEMPLATE/feedback.yml`:

```yaml
name: Feedback
description: Suggestion, feature request, or general feedback
title: "Feedback: "
labels: ["feedback"]
body:
  - type: textarea
    id: details
    attributes:
      label: What's on your mind?
      description: Tell us what you'd like to see, or what's working / not working for you.
    validations:
      required: true
```

- [ ] **Step 3: Verify templates load (manual, post-push)**

After this is merged and pushed, visiting `https://github.com/tfredricks/voxline/issues/new?template=bug.yml` should land on the bug form. (Cannot verify pre-push; recorded as manual smoke test in Task 11.)

- [ ] **Step 4: Commit**

```bash
git add .github/ISSUE_TEMPLATE/bug.yml .github/ISSUE_TEMPLATE/feedback.yml
git commit -m "chore(github): add bug + feedback issue templates"
```

---

## Task 3: LoginItemService (SMAppService wrapper)

Thin wrapper with a protocol seam so we can stub `SMAppService.Status` and register/unregister calls in tests.

**Files:**
- Create: `voxline/Settings/LoginItemService.swift`
- Create: `voxlineTests/LoginItemServiceTests.swift`

- [ ] **Step 1: Write failing tests**

Create `voxlineTests/LoginItemServiceTests.swift`:

```swift
import Testing
import Foundation
import ServiceManagement
@testable import voxline

@Suite @MainActor struct LoginItemServiceTests {

    @Test func status_maps_enabled() {
        let svc = LoginItemService(backend: StubLoginBackend(status: .enabled))
        #expect(svc.status == .enabled)
    }

    @Test func status_maps_notRegistered_to_disabled() {
        let svc = LoginItemService(backend: StubLoginBackend(status: .notRegistered))
        #expect(svc.status == .disabled)
    }

    @Test func status_maps_notFound_to_disabled() {
        let svc = LoginItemService(backend: StubLoginBackend(status: .notFound))
        #expect(svc.status == .disabled)
    }

    @Test func status_maps_requiresApproval() {
        let svc = LoginItemService(backend: StubLoginBackend(status: .requiresApproval))
        #expect(svc.status == .requiresApproval)
    }

    @Test func setEnabled_true_calls_register_and_updates_status() throws {
        let backend = StubLoginBackend(status: .notRegistered)
        let svc = LoginItemService(backend: backend)
        try svc.setEnabled(true)
        #expect(backend.registerCount == 1)
        #expect(backend.unregisterCount == 0)
        #expect(svc.status == .enabled)
    }

    @Test func setEnabled_false_calls_unregister_and_updates_status() throws {
        let backend = StubLoginBackend(status: .enabled)
        let svc = LoginItemService(backend: backend)
        try svc.setEnabled(false)
        #expect(backend.registerCount == 0)
        #expect(backend.unregisterCount == 1)
        #expect(svc.status == .disabled)
    }

    @Test func setEnabled_true_can_yield_requires_approval() throws {
        let backend = StubLoginBackend(status: .notRegistered)
        backend.registerYields = .requiresApproval
        let svc = LoginItemService(backend: backend)
        try svc.setEnabled(true)
        #expect(svc.status == .requiresApproval)
    }
}

@MainActor
final class StubLoginBackend: LoginItemBackend {
    var status: SMAppService.Status
    var registerYields: SMAppService.Status?
    var registerCount = 0
    var unregisterCount = 0

    init(status: SMAppService.Status) { self.status = status }

    func register() throws {
        registerCount += 1
        status = registerYields ?? .enabled
    }

    func unregister() throws {
        unregisterCount += 1
        status = .notRegistered
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme voxline -destination 'platform=macOS' test -only-testing:voxlineTests/LoginItemServiceTests 2>&1 | tail -30`
Expected: build error — `LoginItemService`, `LoginItemBackend` not defined.

- [ ] **Step 3: Implement LoginItemService**

Create `voxline/Settings/LoginItemService.swift`:

```swift
import Foundation
import ServiceManagement

@MainActor
protocol LoginItemBackend {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

@MainActor
struct DefaultLoginItemBackend: LoginItemBackend {
    private let service = SMAppService.mainApp
    var status: SMAppService.Status { service.status }
    func register() throws { try service.register() }
    func unregister() throws { try service.unregister() }
}

@MainActor
final class LoginItemService {
    enum Status: Equatable {
        case enabled
        case disabled
        case requiresApproval
        case unsupported
    }

    private let backend: LoginItemBackend

    init(backend: LoginItemBackend = DefaultLoginItemBackend()) {
        self.backend = backend
    }

    var status: Status {
        switch backend.status {
        case .enabled: return .enabled
        case .notRegistered: return .disabled
        case .notFound: return .disabled
        case .requiresApproval: return .requiresApproval
        @unknown default: return .unsupported
        }
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try backend.register()
        } else {
            try backend.unregister()
        }
    }
}
```

Add both files to the Xcode project (target `voxline` and `voxlineTests` respectively).

- [ ] **Step 4: Run tests**

Run: `xcodebuild -scheme voxline -destination 'platform=macOS' test -only-testing:voxlineTests/LoginItemServiceTests 2>&1 | tail -30`
Expected: PASS — 7 tests.

- [ ] **Step 5: Commit**

```bash
git add voxline/Settings/LoginItemService.swift voxlineTests/LoginItemServiceTests.swift voxline.xcodeproj
git commit -m "feat(settings): LoginItemService wrapping SMAppService.mainApp"
```

---

## Task 4: Wire launchAtLogin into GeneralSettingsViewModel

The toggle bypasses the `commit() / GeneralSettingsSnapshot` path because Launch-at-Login isn't propagated to the audio pipeline — it's a local-only side effect on `LoginItemService`.

**Files:**
- Modify: `voxline/Settings/GeneralSettingsViewModel.swift`
- Modify: `voxlineTests/GeneralSettingsViewModelTests.swift`

- [ ] **Step 1: Write failing tests**

Append to `voxlineTests/GeneralSettingsViewModelTests.swift`, inside the existing `@Suite @MainActor struct GeneralSettingsViewModelTests`:

```swift
@Test func launch_at_login_initialized_from_login_item_status() {
    let backend = StubLoginBackend(status: .enabled)
    let svc = LoginItemService(backend: backend)
    let vm = GeneralSettingsViewModel(
        settings: AppSettings(defaults: defaults()),
        applier: NoopApplier(),
        loginItemService: svc
    )
    #expect(vm.launchAtLogin == true)
    #expect(vm.loginItemStatus == .enabled)
}

@Test func launch_at_login_disabled_when_not_registered() {
    let backend = StubLoginBackend(status: .notRegistered)
    let svc = LoginItemService(backend: backend)
    let vm = GeneralSettingsViewModel(
        settings: AppSettings(defaults: defaults()),
        applier: NoopApplier(),
        loginItemService: svc
    )
    #expect(vm.launchAtLogin == false)
    #expect(vm.loginItemStatus == .disabled)
}

@Test func toggling_launch_at_login_to_true_calls_register() throws {
    let backend = StubLoginBackend(status: .notRegistered)
    let svc = LoginItemService(backend: backend)
    let vm = GeneralSettingsViewModel(
        settings: AppSettings(defaults: defaults()),
        applier: NoopApplier(),
        loginItemService: svc
    )
    vm.launchAtLogin = true
    #expect(backend.registerCount == 1)
    #expect(vm.loginItemStatus == .enabled)
    #expect(vm.launchAtLogin == true)
}

@Test func toggling_launch_at_login_to_false_calls_unregister() throws {
    let backend = StubLoginBackend(status: .enabled)
    let svc = LoginItemService(backend: backend)
    let vm = GeneralSettingsViewModel(
        settings: AppSettings(defaults: defaults()),
        applier: NoopApplier(),
        loginItemService: svc
    )
    vm.launchAtLogin = false
    #expect(backend.unregisterCount == 1)
    #expect(vm.loginItemStatus == .disabled)
    #expect(vm.launchAtLogin == false)
}

@Test func register_yielding_requires_approval_keeps_toggle_off() {
    let backend = StubLoginBackend(status: .notRegistered)
    backend.registerYields = .requiresApproval
    let svc = LoginItemService(backend: backend)
    let vm = GeneralSettingsViewModel(
        settings: AppSettings(defaults: defaults()),
        applier: NoopApplier(),
        loginItemService: svc
    )
    vm.launchAtLogin = true
    #expect(vm.loginItemStatus == .requiresApproval)
    #expect(vm.launchAtLogin == false)
}

@Test func refresh_login_item_status_picks_up_external_approval() {
    let backend = StubLoginBackend(status: .requiresApproval)
    let svc = LoginItemService(backend: backend)
    let vm = GeneralSettingsViewModel(
        settings: AppSettings(defaults: defaults()),
        applier: NoopApplier(),
        loginItemService: svc
    )
    #expect(vm.launchAtLogin == false)
    backend.status = .enabled
    vm.refreshLoginItemStatus()
    #expect(vm.loginItemStatus == .enabled)
    #expect(vm.launchAtLogin == true)
}
```

(Note: `StubLoginBackend` lives in `LoginItemServiceTests.swift`. To make it visible to this test file, mark it as `internal` — i.e., remove `private` if present, or move it to a small shared `voxlineTests/TestSupport/StubLoginBackend.swift` if you prefer. Recommended: drop the `private` qualifier on `StubLoginBackend` in `LoginItemServiceTests.swift` so it's `internal` to the `voxlineTests` module.)

- [ ] **Step 2: Drop `private` on StubLoginBackend**

Edit `voxlineTests/LoginItemServiceTests.swift`: change

```swift
@MainActor
final class StubLoginBackend: LoginItemBackend {
```

(it should already be unprefixed `final class` per the Task 3 listing — confirm no `private` was added during drift). The class should be at file scope, not inside the `@Suite` struct.

- [ ] **Step 3: Run test to verify it fails**

Run: `xcodebuild -scheme voxline -destination 'platform=macOS' test -only-testing:voxlineTests/GeneralSettingsViewModelTests 2>&1 | tail -30`
Expected: build error — `loginItemService:` parameter and `launchAtLogin` / `loginItemStatus` / `refreshLoginItemStatus` don't exist on the VM.

- [ ] **Step 4: Extend GeneralSettingsViewModel**

Modify `voxline/Settings/GeneralSettingsViewModel.swift`. The full updated file:

```swift
import Foundation
import Observation

struct AudioDeviceRow: Identifiable, Equatable {
    let uid: String?
    let label: String
    var id: String { uid ?? "__system_default__" }
}

@Observable
@MainActor
final class GeneralSettingsViewModel {

    var chord: HotkeyChord { didSet { if loaded { commit() } } }
    var audioInputDeviceUID: String? { didSet { if loaded { commit() } } }
    var whisperModel: WhisperModel { didSet { if loaded { commit() } } }
    var playHotkeySounds: Bool { didSet { if loaded { commit() } } }
    var provider: LLMProvider { didSet { if loaded { commit() } } }

    var launchAtLogin: Bool {
        didSet {
            guard loaded, oldValue != launchAtLogin else { return }
            applyLaunchAtLogin()
        }
    }
    private(set) var loginItemStatus: LoginItemService.Status

    private(set) var devices: [AudioDevice] = []

    private var settings: AppSettings
    private let applier: GeneralSettingsApplier
    private let deviceEnumerator: () -> [AudioDevice]
    private var deviceListener: AudioDeviceListener?
    private let loginItemService: LoginItemService
    private var loaded = false

    init(
        settings: AppSettings = AppSettings(),
        applier: GeneralSettingsApplier,
        deviceEnumerator: @escaping () -> [AudioDevice] = AudioDeviceEnumerator.inputDevices,
        loginItemService: LoginItemService = LoginItemService()
    ) {
        self.settings = settings
        self.applier = applier
        self.deviceEnumerator = deviceEnumerator
        self.loginItemService = loginItemService
        self.chord = settings.hotkeyChord
        self.audioInputDeviceUID = settings.audioInputDeviceUID
        self.whisperModel = settings.whisperModel
        self.playHotkeySounds = settings.playHotkeySounds
        self.provider = settings.llmProvider
        let initialStatus = loginItemService.status
        self.loginItemStatus = initialStatus
        self.launchAtLogin = (initialStatus == .enabled)
        self.devices = deviceEnumerator()
        self.loaded = true
        self.deviceListener = AudioDeviceListener { [weak self] in
            MainActor.assumeIsolated { self?.refreshDevices() }
        }
    }

    var deviceRows: [AudioDeviceRow] {
        var rows: [AudioDeviceRow] = [AudioDeviceRow(uid: nil, label: "System default")]
        for d in devices {
            let suffix = d.isDefault ? " (default)" : ""
            rows.append(AudioDeviceRow(uid: d.uid, label: d.name + suffix))
        }
        if let uid = audioInputDeviceUID, !devices.contains(where: { $0.uid == uid }) {
            rows.append(AudioDeviceRow(uid: uid, label: "(disconnected) previously selected"))
        }
        return rows
    }

    func refreshDevices() {
        devices = deviceEnumerator()
    }

    /// Re-reads `LoginItemService.status` and reconciles `launchAtLogin` to it.
    /// Called after every toggle and on Settings-window-becomes-key, so external
    /// approval/revocation in System Settings → Login Items reflects back.
    func refreshLoginItemStatus() {
        let s = loginItemService.status
        loginItemStatus = s
        let actual = (s == .enabled)
        if launchAtLogin != actual {
            loaded = false
            launchAtLogin = actual
            loaded = true
        }
    }

    /// Restore Spec defaults: hotkey to Left Ctrl + Left Option, system-default
    /// mic, large-v3-turbo, sounds on. Performs one batched commit so the
    /// applier sees a single coherent snapshot rather than four partial ones.
    /// Launch-at-Login is intentionally left untouched — Reset is for pipeline
    /// settings, not OS-level integration.
    func resetToDefaults() {
        loaded = false
        chord = .default
        audioInputDeviceUID = nil
        whisperModel = .default
        playHotkeySounds = true
        provider = .anthropic
        loaded = true
        commit()
    }

    private func applyLaunchAtLogin() {
        // The setter throws on signing/Tcc issues. Reconcile state to actual
        // backend status either way so the UI doesn't lie.
        try? loginItemService.setEnabled(launchAtLogin)
        refreshLoginItemStatus()
    }

    private func commit() {
        var s = settings
        s.hotkeyChord = chord
        s.audioInputDeviceUID = audioInputDeviceUID
        s.whisperModel = whisperModel
        s.playHotkeySounds = playHotkeySounds
        s.llmProvider = provider
        settings = s
        applier.apply(GeneralSettingsSnapshot(
            chord: chord,
            audioInputDeviceUID: audioInputDeviceUID,
            whisperModel: whisperModel,
            playHotkeySounds: playHotkeySounds,
            provider: provider
        ))
    }
}
```

- [ ] **Step 5: Run tests**

Run: `xcodebuild -scheme voxline -destination 'platform=macOS' test -only-testing:voxlineTests/GeneralSettingsViewModelTests 2>&1 | tail -40`
Expected: PASS — all existing tests + 6 new tests.

- [ ] **Step 6: Commit**

```bash
git add voxline/Settings/GeneralSettingsViewModel.swift voxlineTests/GeneralSettingsViewModelTests.swift
git commit -m "feat(settings): launchAtLogin toggle + loginItemStatus on GeneralSettingsViewModel"
```

---

## Task 5: Add Startup section to SettingsView

Pure UI; no unit test. Manual verification only (covered in Task 11).

**Files:**
- Modify: `voxline/Settings/SettingsView.swift`

- [ ] **Step 1: Add Startup section at top of Form**

Edit `voxline/Settings/SettingsView.swift`. Replace the `Form { ... }` block. The new section goes immediately above `Section("Hotkey")`. Add `import AppKit` at the top if not already present (needed for `NSWorkspace`).

After the existing `import SwiftUI` line, ensure:

```swift
import SwiftUI
import AppKit
```

Inside the Form, add at the top (just after the opening `Form {`):

```swift
Section("Startup") {
    Toggle("Launch voxline at login", isOn: $generalVM.launchAtLogin)
    if generalVM.loginItemStatus == .requiresApproval {
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
}
```

Then, on the `Form` itself (or on the outer `VStack` containing it), add a `.task` that refreshes status when the view appears, and an `.onChange` so it also refreshes when the window comes back to focus. Place this with the other view modifiers (next to `.onAppear { ... }`):

```swift
.task { generalVM.refreshLoginItemStatus() }
```

- [ ] **Step 2: Build the app to verify it compiles**

Run: `xcodebuild -scheme voxline -destination 'platform=macOS' build 2>&1 | tail -20`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Run the full test suite to verify nothing regressed**

Run: `xcodebuild -scheme voxline -destination 'platform=macOS' test 2>&1 | tail -40`
Expected: all tests PASS.

- [ ] **Step 4: Commit**

```bash
git add voxline/Settings/SettingsView.swift
git commit -m "feat(settings): Startup section with Launch at Login toggle + approval hint"
```

---

## Task 6: AboutView (SwiftUI)

Pure SwiftUI rendering; no unit test (visual review only).

**Files:**
- Create: `voxline/UI/AboutView.swift`

- [ ] **Step 1: Implement AboutView**

Create `voxline/UI/AboutView.swift`:

```swift
import SwiftUI
import AppKit

struct AboutView: View {
    let env: SupportEnvironment

    var body: some View {
        VStack(spacing: 16) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 64, height: 64)
            }

            VStack(spacing: 2) {
                Text("voxline")
                    .font(.title)
                    .fontWeight(.semibold)
                Text("Version \(env.appVersion) (\(env.buildNumber))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 2) {
                Text("Local-first dictation for Mac.")
                Text("Audio never leaves your Mac.")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)

            VStack(spacing: 8) {
                Button {
                    NSWorkspace.shared.open(SupportLinks.repoURL)
                } label: {
                    Text("Visit GitHub").frame(maxWidth: .infinity)
                }
                Button {
                    NSWorkspace.shared.open(SupportLinks.bugReportURL(env: env))
                } label: {
                    Text("Report a Bug…").frame(maxWidth: .infinity)
                }
                Button {
                    NSWorkspace.shared.open(SupportLinks.feedbackURL(env: env))
                } label: {
                    Text("Send Feedback…").frame(maxWidth: .infinity)
                }
            }
            .controlSize(.large)

            Spacer(minLength: 4)

            VStack(spacing: 2) {
                Text("Built with WhisperKit")
                Text("© 2026 Todd Fredricks")
            }
            .font(.footnote)
            .foregroundStyle(.tertiary)
        }
        .padding(20)
        .frame(width: 320, height: 420)
    }
}

#Preview {
    AboutView(env: SupportEnvironment(
        appVersion: "1.0",
        buildNumber: "1",
        osVersion: "Version 14.5 (Build 23F79)",
        whisperModel: "large-v3-turbo",
        micDevice: "MacBook Pro Microphone"
    ))
}
```

Add the file to the Xcode project (target `voxline`).

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild -scheme voxline -destination 'platform=macOS' build 2>&1 | tail -20`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add voxline/UI/AboutView.swift voxline.xcodeproj
git commit -m "feat(ui): AboutView with app icon, version, links, attribution"
```

---

## Task 7: AboutWindowController

Hosts `AboutView` in an `NSWindow` and tags it as dockworthy so the upcoming `WindowVisibilityCoordinator` counts it.

**Files:**
- Create: `voxline/UI/AboutWindowController.swift`

- [ ] **Step 1: Implement AboutWindowController**

Create `voxline/UI/AboutWindowController.swift`:

```swift
import AppKit
import SwiftUI

@MainActor
final class AboutWindowController {
    private var window: NSWindow?

    func show(env: SupportEnvironment) {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let host = NSHostingView(rootView: AboutView(env: env))
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "About voxline"
        win.contentView = host
        win.center()
        win.isReleasedWhenClosed = false
        win.identifier = WindowVisibilityCoordinator.dockworthyIdentifier
        self.window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}
```

This file references `WindowVisibilityCoordinator.dockworthyIdentifier`, which is added in Task 9. To avoid a temporary build break, **either reorder Task 7 after Task 9, or stub the constant inline**. Recommended: reorder — do Task 9 first, then this. If you're proceeding sequentially, defer Task 7 until after Task 9 is committed.

(Note for the agent: skip ahead to Task 9, complete it, then return to Task 7. Tasks are otherwise independent.)

Add the file to the Xcode project (target `voxline`).

- [ ] **Step 2: Build to verify it compiles (after Task 9 is done)**

Run: `xcodebuild -scheme voxline -destination 'platform=macOS' build 2>&1 | tail -20`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add voxline/UI/AboutWindowController.swift voxline.xcodeproj
git commit -m "feat(ui): AboutWindowController hosting AboutView, tagged dockworthy"
```

---

## Task 8: Wire About into MenuBarContent + AppDelegate

Adds the menu item and threads the open-about closure through `voxlineApp`. Also adds a `Settings…` post-action that tags the SwiftUI Settings window as dockworthy (needed by Task 9's coordinator).

**Files:**
- Modify: `voxline/MenuBar/MenuBarContent.swift`
- Modify: `voxline/voxlineApp.swift`

- [ ] **Step 1: Update MenuBarContent**

Replace the body of `voxline/MenuBar/MenuBarContent.swift`:

```swift
// voxline/MenuBar/MenuBarContent.swift
import AppKit
import SwiftUI

struct MenuBarContent: View {
    @Bindable var state: AppState
    @Environment(\.openSettings) private var openSettings

    var openDebugWindow: () -> Void = {}
    var openAboutWindow: () -> Void = {}
    var tagSettingsWindow: () -> Void = {}

    var body: some View {
        if case .error(_, let message) = state.status {
            Text(message)
                .foregroundStyle(.red)
            Divider()
        }

        if case .downloadingModel(let p) = state.status {
            Text("Downloading model — \(Int(p * 100))%")
                .foregroundStyle(.secondary)
            Divider()
        }

        Button(state.hotkeyEnabled ? "Pause voxline" : "Resume voxline") {
            state.hotkeyEnabled.toggle()
        }
        Divider()

        Button("Settings…") {
            openSettings()
            NSApp.activate()
            tagSettingsWindow()
        }
        .keyboardShortcut(",")

        #if DEBUG
        Divider()
        Button("Debug…") { openDebugWindow() }
        #endif

        Divider()

        Button("About voxline") { openAboutWindow() }

        Divider()

        Button("Quit voxline") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
```

- [ ] **Step 2: Wire the closures in voxlineApp**

Edit `voxline/voxlineApp.swift`. Update the `MenuBarExtra` body to pass the new closures, and add an `aboutWindow` property + a small helper on `AppDelegate` for the SupportEnvironment.

Replace the `MenuBarExtra { ... }` block:

```swift
MenuBarExtra {
    MenuBarContent(
        state: delegate.appState,
        openDebugWindow: {
            delegate.debugWindow.show(
                state: delegate.appState,
                coordinator: delegate.coordinator
            )
        },
        openAboutWindow: {
            delegate.showAboutWindow()
        },
        tagSettingsWindow: {
            delegate.tagSettingsWindowSoon()
        }
    )
} label: {
    MenuBarLabel(state: delegate.appState)
}
.menuBarExtraStyle(.menu)
```

Then in the `AppDelegate` class, add:

```swift
let aboutWindow = AboutWindowController()
let windowVisibility = WindowVisibilityCoordinator()

func showAboutWindow() {
    let env = SupportEnvironment.current(
        whisperModel: coordinator.transcriber?.model.displayName ?? "(unknown)",
        micDevice: nil
    )
    aboutWindow.show(env: env)
}

func tagSettingsWindowSoon() {
    windowVisibility.tagSettingsWindowAfterOpen()
}
```

Note: `windowVisibility` and `tagSettingsWindowAfterOpen()` are added in Task 9. If you're doing tasks in numerical order, this step won't compile until Task 9 is finished. Recommended order is **Task 9 → Task 7 → Task 8** for a clean build trail; commit Task 8 last.

The micDevice can stay `nil` for now (system-default fallback in the body); a future polish task can resolve the actual device name from `AudioCaptureService`.

- [ ] **Step 3: Build (after Tasks 9 and 7 are also done)**

Run: `xcodebuild -scheme voxline -destination 'platform=macOS' build 2>&1 | tail -20`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add voxline/MenuBar/MenuBarContent.swift voxline/voxlineApp.swift
git commit -m "feat(menu): About voxline menu item, wire AboutWindowController"
```

---

## Task 9: WindowVisibilityCoordinator

Counts dock-worthy windows and flips `NSApp.activationPolicy` accordingly. Fully testable via injected `NotificationCenter` + `ActivationPolicySetter`.

**Files:**
- Create: `voxline/MenuBar/WindowVisibilityCoordinator.swift`
- Create: `voxlineTests/WindowVisibilityCoordinatorTests.swift`

- [ ] **Step 1: Write failing tests**

Create `voxlineTests/WindowVisibilityCoordinatorTests.swift`:

```swift
import Testing
import AppKit
@testable import voxline

@Suite @MainActor struct WindowVisibilityCoordinatorTests {

    @Test func tagged_window_made_visible_flips_to_regular() {
        let center = NotificationCenter()
        let setter = StubActivationSetter()
        let coord = WindowVisibilityCoordinator(center: center, setter: setter)
        coord.start()

        let w = makeStubWindow(dockworthy: true)
        center.post(name: NSWindow.didBecomeVisibleNotification, object: w)
        #expect(setter.policies == [.regular])
        #expect(setter.activateCount == 1)
    }

    @Test func untagged_window_made_visible_does_nothing() {
        let center = NotificationCenter()
        let setter = StubActivationSetter()
        let coord = WindowVisibilityCoordinator(center: center, setter: setter)
        coord.start()

        let w = makeStubWindow(dockworthy: false)
        center.post(name: NSWindow.didBecomeVisibleNotification, object: w)
        #expect(setter.policies.isEmpty)
        #expect(setter.activateCount == 0)
    }

    @Test func closing_last_tagged_window_returns_to_accessory() {
        let center = NotificationCenter()
        let setter = StubActivationSetter()
        let coord = WindowVisibilityCoordinator(center: center, setter: setter)
        coord.start()

        let w = makeStubWindow(dockworthy: true)
        center.post(name: NSWindow.didBecomeVisibleNotification, object: w)
        center.post(name: NSWindow.willCloseNotification, object: w)
        #expect(setter.policies == [.regular, .accessory])
    }

    @Test func two_tagged_windows_only_flip_once_per_direction() {
        let center = NotificationCenter()
        let setter = StubActivationSetter()
        let coord = WindowVisibilityCoordinator(center: center, setter: setter)
        coord.start()

        let a = makeStubWindow(dockworthy: true)
        let b = makeStubWindow(dockworthy: true)
        center.post(name: NSWindow.didBecomeVisibleNotification, object: a)
        center.post(name: NSWindow.didBecomeVisibleNotification, object: b)
        center.post(name: NSWindow.willCloseNotification, object: a)
        #expect(setter.policies == [.regular])  // not yet back to accessory
        center.post(name: NSWindow.willCloseNotification, object: b)
        #expect(setter.policies == [.regular, .accessory])
    }

    @Test func same_window_visible_twice_only_increments_once() {
        let center = NotificationCenter()
        let setter = StubActivationSetter()
        let coord = WindowVisibilityCoordinator(center: center, setter: setter)
        coord.start()

        let w = makeStubWindow(dockworthy: true)
        center.post(name: NSWindow.didBecomeVisibleNotification, object: w)
        center.post(name: NSWindow.didBecomeVisibleNotification, object: w)
        center.post(name: NSWindow.willCloseNotification, object: w)
        #expect(setter.policies == [.regular, .accessory])
    }

    private func makeStubWindow(dockworthy: Bool) -> NSWindow {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        if dockworthy {
            w.identifier = WindowVisibilityCoordinator.dockworthyIdentifier
        }
        return w
    }
}

@MainActor
final class StubActivationSetter: ActivationPolicySetter {
    var policies: [NSApplication.ActivationPolicy] = []
    var activateCount = 0
    func setPolicy(_ p: NSApplication.ActivationPolicy) { policies.append(p) }
    func activate() { activateCount += 1 }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme voxline -destination 'platform=macOS' test -only-testing:voxlineTests/WindowVisibilityCoordinatorTests 2>&1 | tail -30`
Expected: build error — `WindowVisibilityCoordinator` and `ActivationPolicySetter` not defined.

- [ ] **Step 3: Implement WindowVisibilityCoordinator**

Create `voxline/MenuBar/WindowVisibilityCoordinator.swift`:

```swift
import AppKit

@MainActor
protocol ActivationPolicySetter {
    func setPolicy(_ policy: NSApplication.ActivationPolicy)
    func activate()
}

@MainActor
struct DefaultActivationPolicySetter: ActivationPolicySetter {
    func setPolicy(_ p: NSApplication.ActivationPolicy) { NSApp.setActivationPolicy(p) }
    func activate() { NSApp.activate() }
}

/// Counts dockworthy windows (those tagged with `dockworthyIdentifier`) and
/// flips `NSApp.activationPolicy` between `.accessory` (zero open) and
/// `.regular` (one or more open). HUD windows (recording pill, model download)
/// are intentionally untagged so they don't trigger the Dock icon.
@MainActor
final class WindowVisibilityCoordinator {
    static let dockworthyIdentifier = NSUserInterfaceItemIdentifier("voxline.dockworthy")

    private let center: NotificationCenter
    private let setter: ActivationPolicySetter
    private var trackedIDs: Set<ObjectIdentifier> = []
    private var observers: [NSObjectProtocol] = []

    init(
        center: NotificationCenter = .default,
        setter: ActivationPolicySetter = DefaultActivationPolicySetter()
    ) {
        self.center = center
        self.setter = setter
    }

    func start() {
        // Seed from windows that were already visible before we started observing.
        for w in NSApp.windows where isDockworthy(w) && w.isVisible {
            insert(w)
        }

        let visibleObserver = center.addObserver(
            forName: NSWindow.didBecomeVisibleNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let w = note.object as? NSWindow else { return }
                if self.isDockworthy(w) { self.insert(w) }
            }
        }
        let closeObserver = center.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let w = note.object as? NSWindow else { return }
                self.remove(w)
            }
        }
        observers = [visibleObserver, closeObserver]
    }

    /// SwiftUI's `Settings` scene constructs its own `NSWindow`, so we tag it
    /// after `openSettings()` runs. Polled briefly because the window may not
    /// yet be `keyWindow` at the moment the menu item handler runs.
    func tagSettingsWindowAfterOpen() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard let self else { return }
            // Find the most likely Settings window: a key/main, titled, non-borderless
            // window that isn't already tagged dockworthy.
            let candidate = NSApp.keyWindow ?? NSApp.mainWindow
            if let w = candidate,
               w.identifier != WindowVisibilityCoordinator.dockworthyIdentifier,
               w.styleMask.contains(.titled),
               !w.styleMask.contains(.borderless) {
                w.identifier = WindowVisibilityCoordinator.dockworthyIdentifier
                if w.isVisible { self.insert(w) }
            }
        }
    }

    private func isDockworthy(_ w: NSWindow) -> Bool {
        w.identifier == WindowVisibilityCoordinator.dockworthyIdentifier
    }

    private func insert(_ w: NSWindow) {
        let id = ObjectIdentifier(w)
        let wasEmpty = trackedIDs.isEmpty
        let inserted = trackedIDs.insert(id).inserted
        if wasEmpty && inserted {
            setter.setPolicy(.regular)
            setter.activate()
        }
    }

    private func remove(_ w: NSWindow) {
        let id = ObjectIdentifier(w)
        let removed = trackedIDs.remove(id) != nil
        if removed && trackedIDs.isEmpty {
            setter.setPolicy(.accessory)
        }
    }

    deinit {
        for o in observers { center.removeObserver(o) }
    }
}
```

Add both files to the Xcode project (`voxline` and `voxlineTests` targets).

- [ ] **Step 4: Run tests**

Run: `xcodebuild -scheme voxline -destination 'platform=macOS' test -only-testing:voxlineTests/WindowVisibilityCoordinatorTests 2>&1 | tail -30`
Expected: PASS — 5 tests.

- [ ] **Step 5: Commit**

```bash
git add voxline/MenuBar/WindowVisibilityCoordinator.swift voxlineTests/WindowVisibilityCoordinatorTests.swift voxline.xcodeproj
git commit -m "feat(menu): WindowVisibilityCoordinator flips activation policy on tagged windows"
```

---

## Task 10: Tag wizard + debug windows; start coordinator in AppDelegate

Wire the coordinator into the app lifecycle and tag the windows it should count (besides About, which is already tagged in Task 7).

**Files:**
- Modify: `voxline/Wizard/FirstRunWindowController.swift`
- Modify: `voxline/Debug/DebugView.swift`
- Modify: `voxline/voxlineApp.swift`

- [ ] **Step 1: Tag the wizard window**

Edit `voxline/Wizard/FirstRunWindowController.swift`. After `win.isReleasedWhenClosed = false` and before `self.window = win`, insert:

```swift
win.identifier = WindowVisibilityCoordinator.dockworthyIdentifier
```

- [ ] **Step 2: Tag the debug window**

Edit `voxline/Debug/DebugView.swift`. In the `DebugWindowController.show(...)` method, after `w.center()` and before `window = w`, insert:

```swift
w.identifier = WindowVisibilityCoordinator.dockworthyIdentifier
```

- [ ] **Step 3: Start the coordinator at app launch**

Edit `voxline/voxlineApp.swift`. In `applicationDidFinishLaunching(_:)`, before `coordinator.startIfNeeded(state: appState)`, add:

```swift
windowVisibility.start()
```

(`windowVisibility` was added as a stored property in Task 8; if Task 8 hasn't been done yet, do it now.)

- [ ] **Step 4: Build and run full tests**

Run: `xcodebuild -scheme voxline -destination 'platform=macOS' test 2>&1 | tail -40`
Expected: all tests PASS, build succeeds.

- [ ] **Step 5: Commit**

```bash
git add voxline/Wizard/FirstRunWindowController.swift voxline/Debug/DebugView.swift voxline/voxlineApp.swift
git commit -m "feat(menu): tag wizard + debug windows dockworthy, start coordinator at launch"
```

---

## Task 11: Manual smoke verification

Pure manual test pass. No commit unless something is fixed; in that case, commit the fix and re-run.

- [ ] **Step 1: Build and launch**

Run: `xcodebuild -scheme voxline -destination 'platform=macOS' build 2>&1 | tail -10`
Then open the built app: `open ~/Library/Developer/Xcode/DerivedData/voxline-*/Build/Products/Debug/voxline.app`

(Or run from Xcode with ⌘R.)

- [ ] **Step 2: Run the smoke matrix**

| Scenario | Expected | ✓/✗ |
|---|---|---|
| Open Settings via menu | Dock icon appears, app shows in Cmd-Tab | |
| Close Settings | Dock icon disappears within ~1s | |
| Open Settings + About simultaneously | Dock icon stays through both | |
| Close About, leave Settings open | Dock icon stays | |
| Close last window | Dock icon disappears | |
| Wizard on first run (delete `~/Library/Preferences/<bundle-id>.plist` first) | Dock icon appears for wizard | |
| Recording pill visible during dictation | Dock icon does **not** appear | |
| Model download window on launch (delete model cache first) | Dock icon does **not** appear | |
| Click "Visit GitHub" in About | Opens repo in browser | |
| Click "Report a Bug…" | Opens GitHub Issues with bug template + env block prefilled (after Task 2 templates land on `main`) | |
| Click "Send Feedback…" | Opens GitHub Issues with feedback template + env block prefilled | |
| Toggle Launch at Login → on (first time) | If status reads `requiresApproval`, inline hint appears with "Approval required…" link | |
| Click hint | Opens System Settings → Login Items | |
| Approve in System Settings, return to voxline Settings | Hint disappears, toggle stays on | |
| Quit and re-login to macOS | voxline auto-launches | |
| Toggle off | App is removed from login items | |

- [ ] **Step 3: If everything passes, the feature is done**

Final consolidated commit (if a smoke fix was needed, commit with a `fix:` prefix and re-test).

---

## Plan self-review checklist (already done by author — included here as audit trail)

- **Spec coverage:**
  - §1 Dock-on-window → Tasks 9, 10 (+ tags in Tasks 7, 10)
  - §2 About dialog → Tasks 6, 7, 8
  - §3 SupportLinks → Task 1 (+ templates in Task 2)
  - §4 Launch at Login → Tasks 3, 4, 5
  - §5 Integration → Tasks 8, 10
- **Type consistency:** `LoginItemService.Status` cases (`enabled`/`disabled`/`requiresApproval`/`unsupported`) consistent across Tasks 3–5. `WindowVisibilityCoordinator.dockworthyIdentifier` referenced consistently in Tasks 7, 9, 10. `SupportEnvironment` fields consistent in Tasks 1, 6, 8.
- **Build-order note:** Task 7 references `WindowVisibilityCoordinator.dockworthyIdentifier` (Task 9), and Task 8 references `windowVisibility` + `tagSettingsWindowAfterOpen` (Task 9). Recommended completion order: 1 → 2 → 3 → 4 → 5 → 6 → **9 → 7 → 8** → 10 → 11. The plan calls this out in Task 7 Step 1 and Task 8 Step 2 so the agent doesn't get caught by the dependency.
