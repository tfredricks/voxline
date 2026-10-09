# Main Window (Home + Settings) and Dock Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give voxline one main window with Home and Settings pages that tucks out of the way when closed. Fix issue #29 by working out the Dock icon from the windows actually on screen.

**Architecture:**
- An AppKit `MainWindowController`, owned by `AppDelegate`, hosts a SwiftUI `NavigationSplitView` (Home, Settings) and replaces the SwiftUI `Settings` scene and the Permissions window.
- A stateless `ActivationPolicyController` replaces `WindowVisibilityCoordinator`. On every window event it works out the activation policy with the pure function `DockPolicy.policy(showInDock:windows:)`, and it applies the result only when it differs from the live policy.
- Launch presentation is a pure decision fed by a login-launch detector, which is chosen by a spike in Task 1.

**Tech Stack:** Swift 6, SwiftUI + AppKit, Swift Testing, Xcode 26 / macOS 26 (Apple Silicon).

**Spec:** `docs/superpowers/specs/2026-10-09-main-window-design.md`

## Global Constraints

- **Precondition:** phase 5 (learning) is merged to `main`. Re-read `voxlineApp.swift`, `AppCoordinator.swift` and `SettingsView.swift` before Tasks 2, 7 and 8, because phase 5 changed them. Where this plan says "copy the `SettingsView(...)` construction", copy whatever is on `main` at that time, including phase 5's `learning:` argument.
- macOS 26 floor and Xcode 26. Not cross-platform.
- The Xcode project uses file-system synchronized folders. New `.swift` files under `voxline/` or `voxlineTests/` are picked up automatically, and deleted files drop out. Never edit `project.pbxproj` for this.
- Tests use Swift Testing (`import Testing`, `@Suite`, `@Test`, `#expect`) and `@testable import voxline`.
- Test command, with a private DerivedData so parallel sessions don't collide:
  `xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO [-only-testing:voxlineTests/<Suite>]`
- No comments that narrate what code does. `///` doc comments only on types and behavior contracts, matching the surrounding code.
- Commits use Conventional Commits (`feat(main-window): …`, `fix(main-window): …`, `docs(main-window): …`) with DCO sign-off (`git commit -s`). End each message with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Field text and selections never go to logs (README privacy promise). New log lines carry states and reasons only.
- User-facing name: "Voxline" (capital V) in window titles and menu items, matching existing copy ("Voxline History", "Quit Voxline").
- New setting: `AppSettings.showInDock`, key `voxline.showInDock`, default `false`.
- Main window: title "Voxline", frame autosave name `voxline.mainWindow`, sidebar pages Home and Settings.

## File map

| File | Responsibility |
|---|---|
| `voxline/MenuBar/DockPolicy.swift` (new) | `WindowSnapshot` and the pure `DockPolicy.policy(showInDock:windows:)` |
| `voxline/MenuBar/ActivationPolicyController.swift` (new) | Observes window and defaults events, applies `DockPolicy`; replaces `WindowVisibilityCoordinator.swift` (deleted) |
| `voxline/LaunchPresentation.swift` (new) | `LaunchPresentation` enum and `decide(...)`; `LoginLaunch` pure check |
| `voxline/LoginLaunchDetector.swift` (new) | Reads the live signals (Apple event and/or login record) chosen in Task 1 |
| `voxline/UI/HomeStatus.swift` (new) | Pure status text for Home |
| `voxline/UI/RecentMeetings.swift` (new) | `RecentMeeting` rows from `MeetingMeta` (pure) |
| `voxline/UI/HomeViewModel.swift` (new) | Observable model behind Home: permissions summary, recent meetings, refresh |
| `voxline/Permissions/PermissionRows.swift` (new) | Permission rows extracted from `PermissionsStatusView` |
| `voxline/UI/HomeView.swift` (new) | Home page UI |
| `voxline/UI/MainWindowController.swift` (new) | `MainWindowPage`, `MainWindowSelection`, the window, and `MainWindowView` |
| `voxline/Permissions/PermissionsStatusView.swift`, `PermissionsWindowController.swift` | Deleted in Task 8 |
| `voxline/Storage/AppSettings.swift`, `voxline/Settings/GeneralSettingsViewModel.swift`, `voxline/Settings/SettingsView.swift` | Show in Dock setting |
| `voxline/voxlineApp.swift` | Scene and `AppDelegate` wiring |
| `voxline/AppCoordinator.swift` | `presentMainWindow` in place of the Permissions window; launch presentation |
| `voxline/MenuBar/MenuBarContent.swift` | Open Voxline, Settings routing, drop Check Permissions |

---

### Task 1: Spike — can voxline tell a login launch from a manual one?

This is a throwaway probe and needs Todd at the keyboard for a logout/login. Its output is a short results section appended to the spec. No code from this task is kept.

**Files:**
- Modify temporarily: `voxline/voxlineApp.swift` (`AppDelegate`)
- Modify: `docs/superpowers/specs/2026-10-09-main-window-design.md` (append results)

- [ ] **Step 1: Add temporary logging in `AppDelegate`**

Add this method to `AppDelegate` in `voxline/voxlineApp.swift`:

```swift
func applicationWillFinishLaunching(_ notification: Notification) {
    let event = NSAppleEventManager.shared().currentAppleEvent
    let eventID = event.map { String(format: "%08x", $0.eventID) } ?? "none"
    let prop = event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue
    let propHex = prop.map { String(format: "%08x", $0) } ?? "none"
    let isLoginItem = prop == keyAELaunchedAsLogInItem
    var sessionStart = "none"
    setutxent()
    while let entry = getutxent() {
        let e = entry.pointee
        guard e.ut_type == USER_PROCESS else { continue }
        let line = withUnsafeBytes(of: e.ut_line) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let user = withUnsafeBytes(of: e.ut_user) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        guard line == "console", user == NSUserName() else { continue }
        sessionStart = "\(Date(timeIntervalSince1970: TimeInterval(e.ut_tv.tv_sec)))"
    }
    endutxent()
    AppLog.pipeline.notice("SPIKE launch: event=\(eventID, privacy: .public) prop=\(propHex, privacy: .public) loginItem=\(isLoginItem, privacy: .public) sessionStart=\(sessionStart, privacy: .public) now=\(Date(), privacy: .public)")
}
```

- [ ] **Step 2: Build and install**

Run: `./scripts/build-local.sh`
Expected: the build succeeds and voxline is installed in `/Applications`.

- [ ] **Step 3: Collect the two cases (Todd)**

1. In a terminal, run `./scripts/tail-logs.sh pipeline | grep SPIKE`.
2. Quit voxline and open it from Finder. Record the line.
3. Turn on Settings → Launch Voxline at login. Log out and back in. Within 2 minutes of logging in, run
   `log show --last 5m --predicate 'subsystem == "com.voxline.app" AND eventMessage CONTAINS "SPIKE"' --style compact`
   and record the line.

- [ ] **Step 4: Decide**

- If `loginItem=true` on the login launch and `false` on the Finder launch: use **Signal A, the Apple event**.
- Otherwise, if `sessionStart` at login is within 60 s of `now`, and the Finder launch was more than 60 s after `sessionStart`: use **Signal B, the login record**.
- If neither works: stop and ask Todd. The fallback is an "Open window when Voxline starts" setting, which changes Task 4.

- [ ] **Step 5: Revert the code and record the result**

Run: `git checkout voxline/voxlineApp.swift`

Append to the spec:

```markdown
## Spike results (YYYY-MM-DD): login-launch detection

| Launch | event | prop | loginItem | sessionStart | now |
|---|---|---|---|---|---|
| Finder | … | … | … | … | … |
| Login | … | … | … | … | … |

Decision: Signal A / Signal B / neither (reason).
```

- [ ] **Step 6: Commit**

```bash
git add docs/superpowers/specs/2026-10-09-main-window-design.md
git commit -s -m "docs(main-window): login-launch detection spike results"
```

---

### Task 2: "Show Voxline in Dock" setting

**Files:**
- Modify: `voxline/Storage/AppSettings.swift`
- Modify: `voxline/Settings/GeneralSettingsViewModel.swift`
- Modify: `voxline/Settings/SettingsView.swift` (Startup section)
- Test: `voxlineTests/AppSettingsTests.swift`, `voxlineTests/GeneralSettingsViewModelTests.swift`

**Interfaces:**
- Produces: `AppSettings.Key.showInDock == "voxline.showInDock"`, `AppSettings.showInDock: Bool` (default false), `GeneralSettingsViewModel.showInDock: Bool`

- [ ] **Step 1: Write the failing tests**

Append inside `AppSettingsTests` (it already has `makeDefaults()`):

```swift
    @Test func show_in_dock_defaults_to_false() {
        #expect(AppSettings(defaults: makeDefaults()).showInDock == false)
    }

    @Test func show_in_dock_round_trips() {
        let defaults = makeDefaults()
        var s = AppSettings(defaults: defaults)
        s.showInDock = true
        #expect(AppSettings(defaults: defaults).showInDock == true)
        #expect(defaults.bool(forKey: "voxline.showInDock") == true)
    }
```

Append inside `GeneralSettingsViewModelTests` (it has `defaults()` and `noopApply`):

```swift
    @Test func show_in_dock_loads_and_persists_without_applying() {
        let d = defaults()
        var settings = AppSettings(defaults: d)
        settings.showInDock = true
        let recorder = ApplyRecorder()
        let vm = GeneralSettingsViewModel(settings: settings, onApply: { recorder.record($0) })
        #expect(vm.showInDock == true)

        vm.showInDock = false
        #expect(AppSettings(defaults: d).showInDock == false)
        #expect(recorder.applied == nil)
    }

    @Test func reset_to_defaults_leaves_show_in_dock_alone() {
        let d = defaults()
        var settings = AppSettings(defaults: d)
        settings.showInDock = true
        let vm = GeneralSettingsViewModel(settings: settings, onApply: noopApply)
        vm.resetToDefaults()
        #expect(vm.showInDock == true)
        #expect(AppSettings(defaults: d).showInDock == true)
    }
```

- [ ] **Step 2: Run the tests to confirm they fail**

Run: `xcodebuild test … -only-testing:voxlineTests/AppSettingsTests -only-testing:voxlineTests/GeneralSettingsViewModelTests`
Expected: the build fails with "value of type 'AppSettings' has no member 'showInDock'".

- [ ] **Step 3: Implement**

In `AppSettings.Key`, add after `meetingCapSeconds`:

```swift
        static let showInDock = "voxline.showInDock"
```

In `AppSettings`, add near the other simple Bool settings:

```swift
    /// When true the app stays a regular Dock app; when false the Dock icon
    /// shows only while a main-level window is open.
    var showInDock: Bool {
        get { defaults.bool(forKey: Key.showInDock) }
        set { defaults.set(newValue, forKey: Key.showInDock) }
    }
```

In `GeneralSettingsViewModel`, add after `launchAtLogin`:

```swift
    var showInDock: Bool {
        didSet {
            guard loaded, oldValue != showInDock else { return }
            settings.showInDock = showInDock
        }
    }
```

In the designated `init`, after `self.launchAtLogin = (initialStatus == .enabled)`:

```swift
        self.showInDock = settings.showInDock
```

In `refreshFromUserDefaults()`, inside `withoutCommitting { … }` after `provider = settings.llmProvider`:

```swift
            showInDock = settings.showInDock
```

In the `resetToDefaults()` doc comment, change "Launch-at-Login and the presets" to "Launch-at-Login, Show in Dock, and the presets".

In `SettingsView`'s `Section("Startup")`, after the `if generalVM.loginItemStatus == .requiresApproval { … }` block:

```swift
                        Toggle("Show Voxline in Dock", isOn: $generalVM.showInDock)
                        Text("When off, Voxline appears in the Dock only while its window is open.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
```

- [ ] **Step 4: Run the tests to confirm they pass**

Run: the same command as Step 2.
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add voxline/Storage/AppSettings.swift voxline/Settings/GeneralSettingsViewModel.swift voxline/Settings/SettingsView.swift voxlineTests/AppSettingsTests.swift voxlineTests/GeneralSettingsViewModelTests.swift
git commit -s -m "feat(main-window): Show Voxline in Dock setting"
```

---

### Task 3: `DockPolicy` and `ActivationPolicyController` (the #29 fix)

**Files:**
- Create: `voxline/MenuBar/DockPolicy.swift`
- Create: `voxline/MenuBar/ActivationPolicyController.swift`
- Delete: `voxline/MenuBar/WindowVisibilityCoordinator.swift`
- Modify: `voxline/voxlineApp.swift` (`AppDelegate`)
- Modify: `voxline/Meetings/MeetingTimerPanel.swift` (doc comment only)
- Test: `voxlineTests/DockPolicyTests.swift`

**Interfaces:**
- Consumes: `AppSettings.showInDock` (Task 2)
- Produces: `struct WindowSnapshot`, `enum DockPolicy { static func policy(showInDock: Bool, windows: [WindowSnapshot]) -> NSApplication.ActivationPolicy }`, `final class ActivationPolicyController { init(center:showInDock:); func start() }`

- [ ] **Step 1: Write the failing tests**

Create `voxlineTests/DockPolicyTests.swift`:

```swift
import AppKit
import Testing
@testable import voxline

@Suite struct DockPolicyTests {

    private func window(
        titled: Bool = true,
        panel: Bool = false,
        level: NSWindow.Level = .normal,
        visible: Bool = true,
        miniaturized: Bool = false
    ) -> WindowSnapshot {
        WindowSnapshot(isTitled: titled, isPanel: panel, level: level, isVisible: visible, isMiniaturized: miniaturized)
    }

    @Test func setting_on_is_regular_even_with_no_windows() {
        #expect(DockPolicy.policy(showInDock: true, windows: []) == .regular)
    }

    @Test func setting_off_with_no_windows_is_accessory() {
        #expect(DockPolicy.policy(showInDock: false, windows: []) == .accessory)
    }

    @Test func visible_titled_window_is_regular() {
        #expect(DockPolicy.policy(showInDock: false, windows: [window()]) == .regular)
    }

    @Test func miniaturized_window_keeps_regular() {
        #expect(DockPolicy.policy(showInDock: false, windows: [window(visible: false, miniaturized: true)]) == .regular)
    }

    @Test func ordered_out_titled_window_is_accessory() {
        #expect(DockPolicy.policy(showInDock: false, windows: [window(visible: false)]) == .accessory)
    }

    @Test func visible_panels_alone_are_accessory() {
        let alert = window(panel: true, level: .modalPanel)
        let pill = window(titled: false, panel: true, level: .statusBar)
        #expect(DockPolicy.policy(showInDock: false, windows: [alert, pill]) == .accessory)
    }

    @Test func titled_window_above_normal_level_is_accessory() {
        #expect(DockPolicy.policy(showInDock: false, windows: [window(level: .floating)]) == .accessory)
    }

    @Test func untitled_window_is_accessory() {
        #expect(DockPolicy.policy(showInDock: false, windows: [window(titled: false)]) == .accessory)
    }

    @Test func one_qualifying_window_among_others_is_regular() {
        let windows = [window(visible: false), window(panel: true), window()]
        #expect(DockPolicy.policy(showInDock: false, windows: windows) == .regular)
    }
}
```

- [ ] **Step 2: Run the tests to confirm they fail**

Run: `xcodebuild test … -only-testing:voxlineTests/DockPolicyTests`
Expected: the build fails with "cannot find 'WindowSnapshot' in scope".

- [ ] **Step 3: Implement `DockPolicy`**

Create `voxline/MenuBar/DockPolicy.swift`:

```swift
import AppKit

struct WindowSnapshot: Equatable {
    var isTitled: Bool
    var isPanel: Bool
    var level: NSWindow.Level
    var isVisible: Bool
    var isMiniaturized: Bool
}

extension WindowSnapshot {
    @MainActor init(_ window: NSWindow) {
        self.init(
            isTitled: window.styleMask.contains(.titled),
            isPanel: window is NSPanel,
            level: window.level,
            isVisible: window.isVisible,
            isMiniaturized: window.isMiniaturized
        )
    }
}

/// Whether voxline should show a Dock icon. Panels (alerts, open panels,
/// the recording pill, the meeting timer) never count, so a panel that is
/// ordered out instead of closed can't leave the icon behind.
enum DockPolicy {
    static func policy(showInDock: Bool, windows: [WindowSnapshot]) -> NSApplication.ActivationPolicy {
        if showInDock { return .regular }
        let hasAppWindow = windows.contains { w in
            w.isTitled && !w.isPanel && w.level == .normal && (w.isVisible || w.isMiniaturized)
        }
        return hasAppWindow ? .regular : .accessory
    }
}
```

- [ ] **Step 4: Run the tests to confirm they pass**

Run: `xcodebuild test … -only-testing:voxlineTests/DockPolicyTests`
Expected: PASS (9 tests).

- [ ] **Step 5: Implement `ActivationPolicyController`**

Create `voxline/MenuBar/ActivationPolicyController.swift`:

```swift
import AppKit

/// Keeps `NSApp.activationPolicy()` equal to `DockPolicy` for the windows on
/// screen right now. Nothing is tracked between events, and the policy is
/// set only when it changes: a redundant `.regular` interrupts AppKit's
/// in-flight activation and flickers the window being shown.
@MainActor
final class ActivationPolicyController {
    private let center: NotificationCenter
    private let showInDock: () -> Bool
    private var observers: [NSObjectProtocol] = []

    init(center: NotificationCenter = .default, showInDock: @escaping () -> Bool = { AppSettings().showInDock }) {
        self.center = center
        self.showInDock = showInDock
    }

    func start() {
        observe(NSWindow.didBecomeKeyNotification) { $0.reevaluate(activating: true) }
        observe(NSWindow.didMiniaturizeNotification) { $0.reevaluate(activating: false) }
        observe(NSWindow.didDeminiaturizeNotification) { $0.reevaluate(activating: false) }
        observe(NSWindow.didChangeOcclusionStateNotification) { $0.reevaluate(activating: false) }
        observe(UserDefaults.didChangeNotification) { $0.reevaluate(activating: false) }
        observe(NSWindow.willCloseNotification) { controller in
            DispatchQueue.main.async { [weak controller] in controller?.reevaluate(activating: false) }
        }
        reevaluate(activating: false)
    }

    private func observe(_ name: Notification.Name, _ handler: @escaping @MainActor (ActivationPolicyController) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                handler(self)
            }
        }
        observers.append(token)
    }

    private func reevaluate(activating: Bool) {
        let target = DockPolicy.policy(showInDock: showInDock(), windows: NSApp.windows.map(WindowSnapshot.init))
        guard target != NSApp.activationPolicy() else { return }
        NSApp.setActivationPolicy(target)
        if target == .regular && activating {
            NSApp.activate()
        }
    }

    deinit {
        for o in observers { center.removeObserver(o) }
    }
}
```

- [ ] **Step 6: Swap it into `AppDelegate`, and delete the old coordinator**

In `voxline/voxlineApp.swift`, replace `let windowVisibility = WindowVisibilityCoordinator()` with:

```swift
    let activationPolicy = ActivationPolicyController()
```

and replace `windowVisibility.start()` with `activationPolicy.start()`.

Run: `git rm voxline/MenuBar/WindowVisibilityCoordinator.swift`

In `voxline/Meetings/MeetingTimerPanel.swift`, change the doc comment's last sentence from "Untitled, so `WindowVisibilityCoordinator` ignores it." to "A panel, so `DockPolicy` ignores it."

- [ ] **Step 7: Run the full suite**

Run: `xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO`
Expected: `** TEST SUCCEEDED **`. If a timing-based suite such as `CapturePipelineStreamingTests` fails, re-run it alone; it is known to flake under parallel build load.

- [ ] **Step 8: Commit**

```bash
git add -A voxline/MenuBar voxline/voxlineApp.swift voxline/Meetings/MeetingTimerPanel.swift voxlineTests/DockPolicyTests.swift
git commit -s -m "fix(main-window): derive the Dock icon from visible windows (#29)"
```

---

### Task 4: Launch presentation and login-launch detection

**Files:**
- Create: `voxline/LaunchPresentation.swift`
- Create: `voxline/LoginLaunchDetector.swift`
- Test: `voxlineTests/LaunchPresentationTests.swift`

**Interfaces:**
- Consumes: the Task 1 decision (Signal A or Signal B)
- Produces: `enum LaunchPresentation: Equatable { case wizard, home, none; static func decide(firstRunComplete: Bool, requiredPermissionsGranted: Bool, launchedAtLogin: Bool) -> LaunchPresentation }`, `enum LoginLaunch { static func isLoginLaunch(appleEventSaysLogin: Bool, sessionStart: Date?, launchedAt: Date, window: TimeInterval = 60) -> Bool }`, `enum LoginLaunchDetector { @MainActor static func capture() -> Bool }`

- [ ] **Step 1: Write the failing tests**

Create `voxlineTests/LaunchPresentationTests.swift`:

```swift
import Foundation
import Testing
@testable import voxline

@Suite struct LaunchPresentationTests {

    @Test func first_run_shows_the_wizard_whatever_else_is_true() {
        for granted in [true, false] {
            for login in [true, false] {
                #expect(LaunchPresentation.decide(firstRunComplete: false, requiredPermissionsGranted: granted, launchedAtLogin: login) == .wizard)
            }
        }
    }

    @Test func missing_permissions_show_home_even_at_login() {
        #expect(LaunchPresentation.decide(firstRunComplete: true, requiredPermissionsGranted: false, launchedAtLogin: true) == .home)
        #expect(LaunchPresentation.decide(firstRunComplete: true, requiredPermissionsGranted: false, launchedAtLogin: false) == .home)
    }

    @Test func login_launch_with_permissions_stays_hidden() {
        #expect(LaunchPresentation.decide(firstRunComplete: true, requiredPermissionsGranted: true, launchedAtLogin: true) == .none)
    }

    @Test func manual_launch_with_permissions_shows_home() {
        #expect(LaunchPresentation.decide(firstRunComplete: true, requiredPermissionsGranted: true, launchedAtLogin: false) == .home)
    }

    @Test func apple_event_login_flag_wins() {
        #expect(LoginLaunch.isLoginLaunch(appleEventSaysLogin: true, sessionStart: nil, launchedAt: Date()))
    }

    @Test func launch_soon_after_session_start_is_login() {
        let start = Date(timeIntervalSince1970: 1_000)
        #expect(LoginLaunch.isLoginLaunch(appleEventSaysLogin: false, sessionStart: start, launchedAt: start.addingTimeInterval(45)))
    }

    @Test func launch_long_after_session_start_is_manual() {
        let start = Date(timeIntervalSince1970: 1_000)
        #expect(!LoginLaunch.isLoginLaunch(appleEventSaysLogin: false, sessionStart: start, launchedAt: start.addingTimeInterval(61)))
    }

    @Test func no_signals_is_manual() {
        #expect(!LoginLaunch.isLoginLaunch(appleEventSaysLogin: false, sessionStart: nil, launchedAt: Date()))
    }
}
```

- [ ] **Step 2: Run the tests to confirm they fail**

Run: `xcodebuild test … -only-testing:voxlineTests/LaunchPresentationTests`
Expected: the build fails with "cannot find 'LaunchPresentation' in scope".

- [ ] **Step 3: Implement the pure parts**

Create `voxline/LaunchPresentation.swift`:

```swift
import Foundation

/// What the app shows by itself at launch.
enum LaunchPresentation: Equatable {
    case wizard, home, none

    static func decide(firstRunComplete: Bool, requiredPermissionsGranted: Bool, launchedAtLogin: Bool) -> LaunchPresentation {
        guard firstRunComplete else { return .wizard }
        guard requiredPermissionsGranted else { return .home }
        return launchedAtLogin ? .none : .home
    }
}

enum LoginLaunch {
    /// A launch counts as "at login" when macOS says so, or when it happened
    /// within `window` seconds of the console session starting.
    static func isLoginLaunch(appleEventSaysLogin: Bool, sessionStart: Date?, launchedAt: Date, window: TimeInterval = 60) -> Bool {
        if appleEventSaysLogin { return true }
        guard let sessionStart else { return false }
        let elapsed = launchedAt.timeIntervalSince(sessionStart)
        return elapsed >= 0 && elapsed <= window
    }
}
```

- [ ] **Step 4: Run the tests to confirm they pass**

Run: same as Step 2.
Expected: PASS (8 tests).

- [ ] **Step 5: Implement the live detector**

Create `voxline/LoginLaunchDetector.swift`. Keep only the signal Task 1 chose:
- **Signal A:** pass `sessionStart: nil`, and delete `consoleSessionStart()`.
- **Signal B:** pass `appleEventSaysLogin: false`, and delete `appleEventSaysLogin()`.

```swift
import AppKit
import Darwin

/// Reads the live launch signals. Call from `applicationWillFinishLaunching`,
/// while the open-application Apple event is still current.
enum LoginLaunchDetector {
    @MainActor static func capture() -> Bool {
        let result = LoginLaunch.isLoginLaunch(
            appleEventSaysLogin: appleEventSaysLogin(),
            sessionStart: consoleSessionStart(),
            launchedAt: Date()
        )
        AppLog.pipeline.info("launch: atLogin=\(result, privacy: .public)")
        return result
    }

    @MainActor private static func appleEventSaysLogin() -> Bool {
        let event = NSAppleEventManager.shared().currentAppleEvent
        return event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    private static func consoleSessionStart() -> Date? {
        setutxent()
        defer { endutxent() }
        var latest: Date?
        while let entry = getutxent() {
            let e = entry.pointee
            guard e.ut_type == USER_PROCESS else { continue }
            let line = withUnsafeBytes(of: e.ut_line) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let user = withUnsafeBytes(of: e.ut_user) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            guard line == "console", user == NSUserName() else { continue }
            let start = Date(timeIntervalSince1970: TimeInterval(e.ut_tv.tv_sec))
            if latest.map({ start > $0 }) ?? true { latest = start }
        }
        return latest
    }
}
```

- [ ] **Step 6: Build**

Run: `xcodebuild build -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO`
Expected: `** BUILD SUCCEEDED **`. Nothing calls the detector yet; Task 8 wires it in.

- [ ] **Step 7: Commit**

```bash
git add voxline/LaunchPresentation.swift voxline/LoginLaunchDetector.swift voxlineTests/LaunchPresentationTests.swift
git commit -s -m "feat(main-window): launch presentation and login-launch detection"
```

---

### Task 5: Home status text, the recent-meetings list and `HomeViewModel`

**Files:**
- Create: `voxline/UI/HomeStatus.swift`
- Create: `voxline/UI/RecentMeetings.swift`
- Create: `voxline/UI/HomeViewModel.swift`
- Test: `voxlineTests/HomeStatusTests.swift`, `voxlineTests/RecentMeetingsTests.swift`, `voxlineTests/HomeViewModelTests.swift`

**Interfaces:**
- Consumes: `AppStatus`, `MenuBarIcon.symbolName(for:paused:meetingRecording:)`, `MeetingMeta`, `MeetingState`, `MeetingController.Phase`, `MeetingStage.label`, `MeetingMarkdown.untitled`, `MeetingStore(root:)`, `MeetingStore.all()`, `PermissionsSummary`, `PermissionsService().summary()`
- Produces:
  - `enum HomeStatus { static func text(for: AppStatus, paused: Bool, meetingRecording: Bool) -> String }`
  - `struct RecentMeeting: Equatable, Identifiable { id, title, startedAt, durationSeconds, notesURL: URL?, stageLabel: String?, showsRetry: Bool }`
  - `enum RecentMeetings { static func rows(metas:phase:lastFailed:fileExists:limit:) -> [RecentMeeting] }`
  - `@Observable @MainActor final class HomeViewModel { init(state:store:permissions:fileExists:); var permissions: PermissionsSummary; var recentMeetings: [RecentMeeting]; var showsMeetings: Bool; func refresh(); func refreshPermissions() }`

- [ ] **Step 1: Write the failing tests**

Create `voxlineTests/HomeStatusTests.swift`:

```swift
import Testing
@testable import voxline

@Suite struct HomeStatusTests {
    @Test func idle_reads_ready_or_paused() {
        #expect(HomeStatus.text(for: .idle, paused: false, meetingRecording: false) == "Ready")
        #expect(HomeStatus.text(for: .idle, paused: true, meetingRecording: false) == "Paused")
    }

    @Test func meeting_recording_while_idle() {
        #expect(HomeStatus.text(for: .idle, paused: false, meetingRecording: true) == "Recording a meeting")
    }

    @Test func active_states() {
        #expect(HomeStatus.text(for: .recording, paused: false, meetingRecording: false) == "Recording")
        #expect(HomeStatus.text(for: .thinking, paused: false, meetingRecording: false) == "Processing")
        #expect(HomeStatus.text(for: .downloadingModel(progress: 0.42), paused: false, meetingRecording: false) == "Downloading model — 42%")
        #expect(HomeStatus.text(for: .preparingModel, paused: false, meetingRecording: false) == "Preparing model…")
    }

    @Test func errors_show_their_message() {
        #expect(HomeStatus.text(for: .error("Mic unplugged"), paused: false, meetingRecording: false) == "Mic unplugged")
        #expect(HomeStatus.text(for: .permissionsError("Needs Accessibility"), paused: true, meetingRecording: false) == "Needs Accessibility")
    }
}
```

Create `voxlineTests/RecentMeetingsTests.swift`:

```swift
import Foundation
import Testing
@testable import voxline

@Suite struct RecentMeetingsTests {

    private func meta(_ seconds: TimeInterval, state: MeetingState = .done, title: String? = "Standup", notes: String? = "/notes/a.md") -> MeetingMeta {
        MeetingMeta(
            id: UUID(), state: state, startedAt: Date(timeIntervalSince1970: seconds), durationSeconds: 600,
            systemTapStarted: true, title: title, notesPath: notes, failureReason: nil
        )
    }

    @Test func newest_first_limited_to_five() {
        let metas = (0..<7).map { meta(TimeInterval($0) * 100) }
        let rows = RecentMeetings.rows(metas: metas, phase: .idle, lastFailed: nil, fileExists: { _ in true })
        #expect(rows.count == 5)
        #expect(rows.map(\.startedAt) == metas.sorted { $0.startedAt > $1.startedAt }.prefix(5).map(\.startedAt))
    }

    @Test func missing_title_uses_untitled() {
        let rows = RecentMeetings.rows(metas: [meta(0, title: nil)], phase: .idle, lastFailed: nil, fileExists: { _ in true })
        #expect(rows.first?.title == MeetingMarkdown.untitled)
    }

    @Test func notes_url_only_when_the_file_exists() {
        let present = meta(0, notes: "/notes/here.md")
        let gone = meta(1, notes: "/notes/gone.md")
        let none = meta(2, notes: nil)
        let rows = RecentMeetings.rows(
            metas: [present, gone, none], phase: .idle, lastFailed: nil,
            fileExists: { $0.path == "/notes/here.md" }
        )
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        #expect(byID[present.id]?.notesURL == URL(fileURLWithPath: "/notes/here.md"))
        #expect(byID[gone.id]?.notesURL == nil)
        #expect(byID[none.id]?.notesURL == nil)
    }

    @Test func in_progress_meetings_show_a_stage() {
        let processing = meta(2, state: .processing, notes: nil)
        let recording = meta(1, state: .recording, notes: nil)
        let waiting = meta(0, state: .recorded, notes: nil)
        let rows = RecentMeetings.rows(
            metas: [processing, recording, waiting], phase: .processing(.writingNotes), lastFailed: nil,
            fileExists: { _ in false }
        )
        #expect(rows[0].stageLabel == "Writing notes…")
        #expect(rows[1].stageLabel == "Recording…")
        #expect(rows[2].stageLabel == "Waiting to process…")
    }

    @Test func processing_without_a_stage_has_a_generic_label() {
        let rows = RecentMeetings.rows(metas: [meta(0, state: .processing)], phase: .processing(nil), lastFailed: nil, fileExists: { _ in false })
        #expect(rows.first?.stageLabel == "Processing…")
    }

    @Test func retry_only_on_the_last_failed_meeting() {
        let failed = meta(1, state: .failed, notes: nil)
        let otherFailed = meta(0, state: .failed, notes: nil)
        let rows = RecentMeetings.rows(metas: [failed, otherFailed], phase: .idle, lastFailed: failed.id, fileExists: { _ in false })
        #expect(rows[0].showsRetry)
        #expect(!rows[1].showsRetry)
        #expect(rows[1].stageLabel == "Failed")
    }
}
```

Create `voxlineTests/HomeViewModelTests.swift`:

```swift
import Foundation
import Testing
@testable import voxline

@Suite @MainActor struct HomeViewModelTests {

    private func makeStore() -> MeetingStore {
        MeetingStore(root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
    }

    private let granted = PermissionsSummary(microphone: .granted, accessibility: .granted, inputMonitoring: .granted)

    @Test func refresh_reads_meetings_from_the_store() throws {
        let store = makeStore()
        var older = try store.create(startedAt: Date(timeIntervalSince1970: 100), systemTapStarted: false)
        older.state = .done
        try store.save(older)
        var newer = try store.create(startedAt: Date(timeIntervalSince1970: 200), systemTapStarted: false)
        newer.state = .done
        try store.save(newer)

        let vm = HomeViewModel(state: AppState(), store: store, permissions: { self.granted }, fileExists: { _ in true })
        vm.refresh()
        #expect(vm.recentMeetings.map(\.id) == [newer.id, older.id])
    }

    @Test func meetings_section_hidden_without_a_meeting_controller() {
        let vm = HomeViewModel(state: AppState(), store: makeStore(), permissions: { self.granted }, fileExists: { _ in true })
        #expect(vm.showsMeetings == false)
    }

    @Test func refresh_permissions_reads_the_summary() {
        var summary = PermissionsSummary(microphone: .denied, accessibility: .granted, inputMonitoring: .granted)
        let vm = HomeViewModel(state: AppState(), store: makeStore(), permissions: { summary }, fileExists: { _ in true })
        vm.refreshPermissions()
        #expect(vm.permissions.requiredGranted == false)
        summary = granted
        vm.refreshPermissions()
        #expect(vm.permissions.requiredGranted == true)
    }
}
```

- [ ] **Step 2: Run the tests to confirm they fail**

Run: `xcodebuild test … -only-testing:voxlineTests/HomeStatusTests -only-testing:voxlineTests/RecentMeetingsTests -only-testing:voxlineTests/HomeViewModelTests`
Expected: the build fails with "cannot find 'HomeStatus' in scope" (and the same for the others).

- [ ] **Step 3: Implement**

Create `voxline/UI/HomeStatus.swift`:

```swift
import Foundation

enum HomeStatus {
    static func text(for status: AppStatus, paused: Bool, meetingRecording: Bool) -> String {
        switch status {
        case .recording: return "Recording"
        case .thinking: return "Processing"
        case .downloadingModel(let progress): return "Downloading model — \(Int(progress * 100))%"
        case .preparingModel: return "Preparing model…"
        case .permissionsError(let message), .error(let message): return message
        case .idle:
            if meetingRecording { return "Recording a meeting" }
            return paused ? "Paused" : "Ready"
        }
    }
}
```

Create `voxline/UI/RecentMeetings.swift`:

```swift
import Foundation

struct RecentMeeting: Equatable, Identifiable {
    let id: UUID
    let title: String
    let startedAt: Date
    let durationSeconds: Double
    /// Nil when the meeting has no notes file or the file is gone.
    let notesURL: URL?
    /// Shown in place of the duration while a meeting isn't finished, or when it failed.
    let stageLabel: String?
    let showsRetry: Bool
}

enum RecentMeetings {
    static func rows(
        metas: [MeetingMeta],
        phase: MeetingController.Phase,
        lastFailed: UUID?,
        fileExists: (URL) -> Bool,
        limit: Int = 5
    ) -> [RecentMeeting] {
        metas
            .sorted { $0.startedAt > $1.startedAt }
            .prefix(limit)
            .map { meta in
                let notesURL = meta.notesPath
                    .map { URL(fileURLWithPath: $0) }
                    .flatMap { fileExists($0) ? $0 : nil }
                return RecentMeeting(
                    id: meta.id,
                    title: meta.title ?? MeetingMarkdown.untitled,
                    startedAt: meta.startedAt,
                    durationSeconds: meta.durationSeconds,
                    notesURL: notesURL,
                    stageLabel: stageLabel(meta.state, phase: phase),
                    showsRetry: meta.id == lastFailed
                )
            }
    }

    private static func stageLabel(_ state: MeetingState, phase: MeetingController.Phase) -> String? {
        switch state {
        case .done: return nil
        case .recording: return "Recording…"
        case .recorded: return "Waiting to process…"
        case .failed: return "Failed"
        case .processing:
            if case .processing(let stage) = phase { return stage?.label ?? "Processing…" }
            return "Processing…"
        }
    }
}
```

Create `voxline/UI/HomeViewModel.swift`:

```swift
import Foundation
import Observation

@Observable
@MainActor
final class HomeViewModel {
    let state: AppState
    private(set) var permissions: PermissionsSummary
    private(set) var recentMeetings: [RecentMeeting] = []

    @ObservationIgnored private let store: MeetingStore?
    @ObservationIgnored private let readPermissions: () -> PermissionsSummary
    @ObservationIgnored private let fileExists: (URL) -> Bool

    init(
        state: AppState,
        store: MeetingStore? = try? MeetingStore.standard(),
        permissions: @escaping () -> PermissionsSummary = { PermissionsService().summary() },
        fileExists: @escaping (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) {
        self.state = state
        self.store = store
        self.readPermissions = permissions
        self.fileExists = fileExists
        self.permissions = permissions()
    }

    var showsMeetings: Bool { state.meetings != nil }

    func refresh() {
        refreshPermissions()
        recentMeetings = RecentMeetings.rows(
            metas: store?.all() ?? [],
            phase: state.meetings?.phase ?? .idle,
            lastFailed: state.meetings?.lastFailedMeeting,
            fileExists: fileExists
        )
    }

    func refreshPermissions() {
        let latest = readPermissions()
        if latest != permissions { permissions = latest }
    }
}
```

- [ ] **Step 4: Run the tests to confirm they pass**

Run: same as Step 2.
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add voxline/UI/HomeStatus.swift voxline/UI/RecentMeetings.swift voxline/UI/HomeViewModel.swift voxlineTests/HomeStatusTests.swift voxlineTests/RecentMeetingsTests.swift voxlineTests/HomeViewModelTests.swift
git commit -s -m "feat(main-window): Home status, recent meetings, and view model"
```

---

### Task 6: `PermissionRows` and `HomeView`

These are SwiftUI views with no unit tests; their logic was tested in Task 5. Verify by building, then check visually in Task 7.

**Files:**
- Create: `voxline/Permissions/PermissionRows.swift`
- Create: `voxline/UI/HomeView.swift`

**Interfaces:**
- Consumes: `HomeViewModel` (Task 5), `HomeStatus`, `MenuBarIcon`, `UpdateService.hasPendingUpdate` / `checkForUpdates()`, `AppSettings().meetingShortcut?.displayName`, `AppSettings().meetingNotesFolder`, `MeetingController.retryFailed()`
- Produces: `struct PermissionRows: View { init(summary: PermissionsSummary, onChange: @escaping () -> Void) }`, `struct HomeView: View { init(model: HomeViewModel) }` (reads `UpdateService` from the environment)

- [ ] **Step 1: Create `PermissionRows`**

Move the row UI and actions out of `PermissionsStatusView` (`row(...)`, `RowTag`, `statusSymbol`, `statusColor`, `openAccessibilitySettings`, `openInputMonitoringSettings`, `openSettingsPane`) into `voxline/Permissions/PermissionRows.swift`. The copy and detail text are unchanged:

```swift
import AppKit
import SwiftUI

struct PermissionRows: View {
    let summary: PermissionsSummary
    var onChange: () -> Void = {}

    @State private var perms = PermissionsService()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            row(
                title: "Accessibility",
                tag: .required,
                detail: "Lets voxline listen for the global hotkey and paste text into other apps.",
                status: summary.accessibility,
                grantLabel: "Open System Settings",
                action: openAccessibilitySettings
            )
            row(
                title: "Microphone",
                tag: .required,
                detail: "Captures your voice for on-device transcription.",
                status: summary.microphone,
                grantLabel: "Grant",
                action: { Task { _ = await perms.requestMicrophone(); onChange() } }
            )
            row(
                title: "Input Monitoring",
                tag: .recommended,
                detail: "Improves global hotkey reliability on some Macs. Grant this if the hotkey doesn't trigger outside voxline's own window.",
                status: summary.inputMonitoring,
                grantLabel: "Grant",
                action: openInputMonitoringSettings
            )
        }
    }

    private enum RowTag {
        case required, recommended
        var label: String { self == .required ? "Required" : "Recommended" }
        var color: Color { self == .required ? .orange : .secondary }
    }

    private func row(
        title: String,
        tag: RowTag,
        detail: String,
        status: PermissionStatus,
        grantLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: status == .granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(status == .granted ? .green : .red)
                .font(.title2)
                .frame(width: 26)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(title).font(.headline)
                    Text(tag.label)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(tag.color)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(tag.color.opacity(0.5)))
                }
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(grantLabel, action: action)
                .disabled(status == .granted)
        }
    }

    private func openAccessibilitySettings() {
        perms.promptAccessibility()
        openSettingsPane("com.apple.preference.security?Privacy_Accessibility")
    }

    private func openInputMonitoringSettings() {
        _ = perms.requestInputMonitoring()
        openSettingsPane("com.apple.preference.security?Privacy_ListenEvent")
        onChange()
    }

    private func openSettingsPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
```

`PermissionsStatusView` stays in place until Task 8 deletes it. It will briefly duplicate this code; that's accepted for one commit.

- [ ] **Step 2: Create `HomeView`**

Create `voxline/UI/HomeView.swift`:

```swift
import AppKit
import Combine
import SwiftUI

struct HomeView: View {
    @Bindable var model: HomeViewModel
    @Environment(UpdateService.self) private var updateService
    @State private var showsPermissionDetails = false

    private let permissionTick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section { statusRow }
            Section("Permissions") { permissions }
            if model.showsMeetings {
                Section("Recent meetings") { meetings }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Home")
        .onAppear { model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in model.refresh() }
        .onReceive(permissionTick) { _ in model.refreshPermissions() }
        .onChange(of: model.state.meetings?.phase) { model.refresh() }
    }

    private var statusRow: some View {
        let state = model.state
        let meetingRecording = state.meetings?.phase.isRecording ?? false
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: MenuBarIcon.symbolName(for: state.status, paused: !state.hotkeyEnabled, meetingRecording: meetingRecording))
                    .font(.title2)
                    .frame(width: 28)
                Text(HomeStatus.text(for: state.status, paused: !state.hotkeyEnabled, meetingRecording: meetingRecording))
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(state.hotkeyEnabled ? "Pause" : "Resume") { state.hotkeyEnabled.toggle() }
            }
            if updateService.hasPendingUpdate {
                Button("Update available — Install") { updateService.checkForUpdates() }
                    .buttonStyle(.link)
            }
        }
    }

    @ViewBuilder
    private var permissions: some View {
        if model.permissions.requiredGranted && !showsPermissionDetails {
            HStack {
                Label("All required permissions granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Spacer()
                Button("Show details") { showsPermissionDetails = true }
                    .buttonStyle(.link)
            }
        } else {
            PermissionRows(summary: model.permissions, onChange: { model.refreshPermissions() })
        }
    }

    @ViewBuilder
    private var meetings: some View {
        if model.recentMeetings.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("No meetings yet")
                if let shortcut = AppSettings().meetingShortcut {
                    Text("Start one from the menu bar or with \(shortcut.displayName).")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            ForEach(model.recentMeetings) { meeting in
                meetingRow(meeting)
            }
        }
        Button("Open meetings folder") {
            NSWorkspace.shared.open(AppSettings().meetingNotesFolder)
        }
    }

    private func meetingRow(_ meeting: RecentMeeting) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.title)
                Text(meeting.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let stage = meeting.stageLabel {
                Text(stage).foregroundStyle(.secondary)
            } else {
                Text(Duration.seconds(meeting.durationSeconds).formatted(.time(pattern: .hourMinute)))
                    .foregroundStyle(.secondary)
            }
            if meeting.showsRetry {
                Button("Retry") { model.state.meetings?.retryFailed() }
                    .disabled(model.state.meetings?.phase != .idle)
            }
            if meeting.notesURL == nil && meeting.stageLabel == nil {
                Text("Notes not available").font(.callout).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if let url = meeting.notesURL { NSWorkspace.shared.open(url) }
        }
        .help(meeting.notesURL == nil ? "" : "Open notes")
    }
}
```

- [ ] **Step 3: Build**

Run: `xcodebuild build -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add voxline/Permissions/PermissionRows.swift voxline/UI/HomeView.swift
git commit -s -m "feat(main-window): Home page and shared permission rows"
```

---

### Task 7: Main window, Settings moved into it, Dock-click reopen, and menu-bar changes

**Files:**
- Create: `voxline/UI/MainWindowController.swift`
- Modify: `voxline/voxlineApp.swift`
- Modify: `voxline/MenuBar/MenuBarContent.swift`

**Interfaces:**
- Consumes: `HomeView(model:)`, `HomeViewModel(state:)` (Tasks 5–6), the `SettingsView(...)` construction currently in `voxlineApp.swift`
- Produces: `enum MainWindowPage: Hashable { case home, settings }`, `final class MainWindowController { init(content: @escaping @MainActor (MainWindowSelection) -> AnyView); func show(_ page: MainWindowPage) }`, `AppDelegate.mainWindow: MainWindowController`, `MenuBarContent.openMainWindow: (MainWindowPage) -> Void`

- [ ] **Step 1: Create the window controller and root view**

Create `voxline/UI/MainWindowController.swift`:

```swift
import AppKit
import Observation
import SwiftUI

enum MainWindowPage: Hashable {
    case home, settings
}

@Observable
@MainActor
final class MainWindowSelection {
    var page: MainWindowPage? = .home
}

/// The app's one primary window: a sidebar with Home and Settings. Created
/// on first `show`, hidden (not released) on close.
@MainActor
final class MainWindowController {
    private var window: NSWindow?
    private let selection = MainWindowSelection()
    private let content: @MainActor (MainWindowSelection) -> AnyView

    init(content: @escaping @MainActor (MainWindowSelection) -> AnyView) {
        self.content = content
    }

    func show(_ page: MainWindowPage) {
        selection.page = page
        if let window {
            window.presentInAccessoryApp()
            return
        }
        let host = NSHostingController(rootView: content(selection))
        let win = NSWindow(contentViewController: host)
        win.title = "Voxline"
        win.styleMask = [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView]
        win.toolbarStyle = .unified
        win.contentMinSize = NSSize(width: 720, height: 480)
        win.isReleasedWhenClosed = false
        if !win.setFrameUsingName("voxline.mainWindow") {
            win.setContentSize(NSSize(width: 880, height: 640))
            win.center()
        }
        win.setFrameAutosaveName("voxline.mainWindow")
        self.window = win
        win.presentInAccessoryApp()
    }
}

struct MainWindowView<Home: View, Settings: View>: View {
    @Bindable var selection: MainWindowSelection
    let home: Home
    let settings: Settings

    var body: some View {
        NavigationSplitView {
            List(selection: $selection.page) {
                Label("Home", systemImage: "house").tag(MainWindowPage.home)
                Label("Settings", systemImage: "gearshape").tag(MainWindowPage.settings)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
        } detail: {
            switch selection.page ?? .home {
            case .home: home
            case .settings: settings
            }
        }
    }
}
```

- [ ] **Step 2: Move the Settings construction into `AppDelegate`**

In `voxline/voxlineApp.swift`:

1. Delete the whole `Settings { … }` scene from `voxlineApp.body`.
2. Add to `AppDelegate`:

```swift
    lazy var mainWindow = MainWindowController { [unowned self] selection in
        AnyView(
            MainWindowView(
                selection: selection,
                home: HomeView(model: HomeViewModel(state: appState)),
                settings: makeSettingsView()
            )
            .environment(appState)
            .environment(updateService)
        )
    }

    private func makeSettingsView() -> some View {
        let coordinator = self.coordinator
        let generalVM = GeneralSettingsViewModel(onApply: { [weak coordinator] snapshot in
            coordinator?.apply(snapshot)
        })
        return SettingsView(
            generalVM: generalVM,
            apiKeysVM: APIKeysSettingsViewModel(onOpenAIKeyChange: { [weak coordinator] in
                coordinator?.openAIKeyDidChange()
            }),
            commandVM: CommandSettingsViewModel(
                chords: { [weak generalVM] in generalVM?.chords ?? AppSettings().chords },
                onChange: { [weak coordinator] in coordinator?.presetsDidChange() },
                reserved: { AppSettings().meetingShortcut.map { [$0] } ?? [] }
            ),
            meetingsVM: MeetingSettingsViewModel(
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

This is the deleted scene's body as it stood before phase 5, plus phase 5's `learning:` argument (`learning: delegate.learning` in the old scene). Before pasting, diff it against the scene on `main`. If phase 5 or anything later added or renamed arguments, the scene on `main` wins; carry its arguments over and change `delegate.x` to `x`. Drop the scene's trailing `.environment(...)` modifiers, because `MainWindowView` applies them.

3. Add the Dock-click handler to `AppDelegate`:

```swift
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        mainWindow.show(.home)
        return false
    }
```

4. On the `MenuBarExtra` scene, after `.menuBarExtraStyle(.menu)`:

```swift
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { delegate.mainWindow.show(.settings) }
                    .keyboardShortcut(",")
            }
        }
```

- [ ] **Step 3: Update the menu-bar menu**

In `voxline/MenuBar/MenuBarContent.swift`:

1. Delete `@Environment(\.openSettings) private var openSettings`.
2. Replace `var openPermissionsWindow: () -> Void = {}` with `var openMainWindow: (MainWindowPage) -> Void = { _ in }`.
3. Make this the first content in `body`, before the error block:

```swift
        Button("Open Voxline") { openMainWindow(.home) }
            .keyboardShortcut("o")

        Divider()
```

4. In the error block, change `Button("Fix permissions…") { openPermissionsWindow() }` to `Button("Fix permissions…") { openMainWindow(.home) }`.
5. Replace the Settings button with:

```swift
        Button("Settings…") { openMainWindow(.settings) }
            .keyboardShortcut(",")
```

6. Delete `Button("Check Permissions…") { openPermissionsWindow() }`.

In `voxlineApp.body`'s `MenuBarContent(...)` call, replace the `openPermissionsWindow: { … }` argument with:

```swift
                openMainWindow: { page in
                    delegate.mainWindow.show(page)
                },
```

- [ ] **Step 4: Build and run the full suite**

Run: `xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Check by hand in the real app**

Run: `./scripts/build-local.sh --debug`, then open `/Applications/voxline.app`.

Check:
1. Menu bar → Open Voxline shows the window on Home.
2. The sidebar switches between Home and Settings, and Settings shows every section that existed before.
3. Closing the window removes the Dock icon (Show in Dock is off).
4. With no window open, clicking the Dock icon while it's still visible, or reopening voxline from Spotlight, shows Home.
5. With the window key, ⌘, switches to Settings.

If the ⌘, item is missing from the app menu, replace `CommandGroup(replacing: .appSettings)` with `CommandGroup(after: .appInfo)` and check again.

- [ ] **Step 6: Commit**

```bash
git add voxline/UI/MainWindowController.swift voxline/voxlineApp.swift voxline/MenuBar/MenuBarContent.swift
git commit -s -m "feat(main-window): main window with Home and Settings; Dock click reopens it"
```

---

### Task 8: Route permissions and launch through the main window; delete the Permissions window

**Files:**
- Modify: `voxline/AppCoordinator.swift`
- Modify: `voxline/voxlineApp.swift` (`AppDelegate`)
- Delete: `voxline/Permissions/PermissionsStatusView.swift`, `voxline/Permissions/PermissionsWindowController.swift`

**Interfaces:**
- Consumes: `LaunchPresentation.decide(...)`, `LoginLaunchDetector.capture()` (Task 4), `AppDelegate.mainWindow` (Task 7)
- Produces: `AppCoordinator.presentMainWindow: (MainWindowPage) -> Void`, and a new parameter `startIfNeeded(state:historyStore:migration:launchedAtLogin:)`

- [ ] **Step 1: Coordinator, replace the Permissions window**

In `voxline/AppCoordinator.swift`:

1. Delete `private let permissionsWindow = PermissionsWindowController()`.
2. Replace `showPermissionsWindow()` and its doc comment with:

```swift
    /// Brings up the main window; set by `AppDelegate` before `startIfNeeded`.
    var presentMainWindow: (MainWindowPage) -> Void = { _ in }
```

3. In `startMeetingRecording()`, replace `showPermissionsWindow()` with `presentMainWindow(.home)`, and change the doc comment's "raises the permissions window instead" to "opens Home instead".
4. In `reconcileTapWithPermissionsAndEnabled`, replace `permissionsWindow.show()` with `presentMainWindow(.home)`. In the comment above it, change "Raise the permissions panel" to "Open Home".
5. At the end of the hotkey installation function (the "Startup guard" block), delete the `if !summary.requiredGranted { permissionsWindow.show() }` statement and its comment. Keep `let summary = perms.summary()` and `lastRequiredGranted = summary.requiredGranted`.

- [ ] **Step 2: Coordinator, launch presentation**

Change the signature to `func startIfNeeded(state: AppState, historyStore: DictationHistoryStore, migration: ContainerMigration.Report? = nil, launchedAtLogin: Bool = false)`.

Replace the `if !settings.hasCompletedFirstRun { … } else { … }` branch with:

```swift
        let presentation = LaunchPresentation.decide(
            firstRunComplete: settings.hasCompletedFirstRun,
            requiredPermissionsGranted: PermissionsService().summary().requiredGranted,
            launchedAtLogin: launchedAtLogin
        )
        AppLog.pipeline.info("launch presentation: \(String(describing: presentation), privacy: .public)")
        switch presentation {
        case .wizard:
            startWizardThenApp(state: state, settings: settings, historyStore: historyStore)
        case .home:
            startApp(state: state, settings: settings, historyStore: historyStore)
            presentMainWindow(.home)
        case .none:
            startApp(state: state, settings: settings, historyStore: historyStore)
        }
```

In `startWizardThenApp`'s `onComplete`, after `self.installHotkey(state: state, settings: settings)`, add:

```swift
                    self.presentMainWindow(.home)
```

- [ ] **Step 3: AppDelegate, detect login and wire the closure**

In `AppDelegate` (`voxline/voxlineApp.swift`):

```swift
    private var launchedAtLogin = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard !LaunchEnvironment.isRunningTests else { return }
        launchedAtLogin = LoginLaunchDetector.capture()
    }
```

In `applicationDidFinishLaunching`, before `coordinator.startIfNeeded(...)`:

```swift
        coordinator.presentMainWindow = { [weak self] page in self?.mainWindow.show(page) }
```

and pass `launchedAtLogin: launchedAtLogin` to `startIfNeeded`.

- [ ] **Step 4: Delete the Permissions window**

Run: `git rm voxline/Permissions/PermissionsStatusView.swift voxline/Permissions/PermissionsWindowController.swift`

Then run: `grep -rn "PermissionsWindowController\|PermissionsStatusView\|showPermissionsWindow\|openPermissionsWindow" voxline voxlineTests`
Expected: no output.

- [ ] **Step 5: Run the full suite**

Run: `xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 6: Check by hand**

Run: `./scripts/build-local.sh --debug`.

Check:
1. Quitting and opening voxline from Finder opens Home.
2. In System Settings, revoke Accessibility for voxline while it runs → Home opens, showing the Accessibility row as missing. Re-grant it → the row turns green within about 1 s.
3. Logging out and back in, with launch at login on → no window and no Dock icon.
   - Check `./scripts/tail-logs.sh pipeline` for `launch: atLogin=true` and `launch presentation: none`.

- [ ] **Step 7: Commit**

```bash
git add -A voxline/AppCoordinator.swift voxline/voxlineApp.swift voxline/Permissions
git commit -s -m "feat(main-window): open Home for permissions and at launch; remove the Permissions window"
```

---

### Task 9: Docs, manual checklist, and closing #29

**Files:**
- Modify: `docs/release/MANUAL_TESTS.md`, `docs/issues.md`, `AGENTS.md`, `README.md`, `CHANGELOG.md`, `docs/superpowers/specs/2026-10-08-voxline-roadmap-design.md`, `docs/superpowers/specs/2026-10-09-main-window-design.md`

- [ ] **Step 1: Manual checklist**

Append to `docs/release/MANUAL_TESTS.md`:

```markdown
## Main window and Dock icon

Show Voxline in Dock is off unless a step says otherwise.

- [ ] Open voxline from Finder → Home opens and the Dock icon shows. Close the window → the Dock icon goes away.
- [ ] Start a meeting, choose Quit Voxline, then Cancel in the confirmation → no Dock icon is left behind. Repeat with each meeting alert (consent, silent system audio, cap warning).
- [ ] Settings → Meetings → choose the notes folder, then Cancel the picker → after closing the main window, no Dock icon is left.
- [ ] With no window open, open voxline from Spotlight → Home opens.
- [ ] Minimize the main window → the Dock icon and the minimized tile stay. Restore it from the Dock.
- [ ] Menu bar → Settings… opens Settings. With the main window key, ⌘, switches to Settings.
- [ ] Put Safari in full screen, then menu bar → Open Voxline → the window appears over the full-screen Space.
- [ ] Turn Show Voxline in Dock on → close the window → the Dock icon stays. Click it → Home opens. Turn it off with no window open → the icon goes.
- [ ] Launch at login on, log out and back in → no window and no Dock icon. The menu bar works.
- [ ] Revoke Accessibility while running → Home opens with Accessibility missing. Re-grant → it turns green within about a second.
- [ ] Home's recent meetings: click a finished meeting → its notes open. "Open meetings folder" → Finder opens the notes folder.
```

- [ ] **Step 2: Issues and roadmap**

In `docs/issues.md`, under `## Open — found 2026-10-09`, change item 29's heading line to start with `29. **Fixed (main window):**` and add one sentence after the existing text:

```markdown
    Fixed by the main window (`docs/superpowers/specs/2026-10-09-main-window-design.md`):
    the Dock icon is worked out from visible non-panel windows on every window event, and a
    Dock click opens Home.
```

In the roadmap spec's issue table, change the #29 row's second column to `Fixed by the main window (2026-10-09 spec)`.

- [ ] **Step 3: AGENTS.md**

In the directory map, add after the `voxline/Output/` bullet:

```markdown
- `voxline/UI/MainWindowController.swift` — the one primary window: a sidebar with Home (`HomeView`/`HomeViewModel`: status, permissions, recent meetings) and Settings (`SettingsView`). It replaced the SwiftUI `Settings` scene and the Permissions window. Closing hides it; a Dock click or the menu bar's Open Voxline shows it. `voxline/MenuBar/ActivationPolicyController.swift` sets the Dock icon from `DockPolicy` (the `voxline.showInDock` setting, else "a titled non-panel window at normal level is visible or minimized") on every window event — never keep a set of tracked windows.
```

- [ ] **Step 4: README**

In `README.md` `## Features`, replace the line starting `- **Menu-bar native**` with:

```markdown
- **Menu-bar native, with a real window when you want it** — a main window with Home (status, permissions, recent meetings) and Settings; close it and voxline keeps running in the menu bar. No Dock icon unless the window is open, or turn on Settings → Show Voxline in Dock.
```

- [ ] **Step 5: CHANGELOG**

Under `## [Unreleased]`, in `### Added`, append:

```markdown
- **Main window.** Open Voxline from the menu bar (or click the Dock icon) for a window with Home — status, permissions, and recent meetings with a link to the notes folder — and Settings, which moved in from its own window. Closing it keeps voxline running in the menu bar. Settings → Show Voxline in Dock keeps the Dock icon all the time; otherwise it shows only while the window is open. Starting at login stays in the menu bar.
```

In `### Fixed` (create the subsection after `### Added` if it doesn't exist), append:

```markdown
- The Dock icon no longer gets stuck with no window behind it after an alert or the folder picker (#29).
```

In `### Removed` (create it if missing), append:

```markdown
- The separate Settings and Permissions windows, and the menu bar's Check Permissions… item; both live in the main window now.
```

- [ ] **Step 6: Spec status**

In `docs/superpowers/specs/2026-10-09-main-window-design.md`, change the `**Status:**` line to `**Status:** Approved; implemented (see plan 2026-10-09-main-window.md).`

- [ ] **Step 7: Commit**

```bash
git add docs/release/MANUAL_TESTS.md docs/issues.md AGENTS.md README.md CHANGELOG.md docs/superpowers/specs/2026-10-08-voxline-roadmap-design.md docs/superpowers/specs/2026-10-09-main-window-design.md
git commit -s -m "docs(main-window): manual checks, changelog, README, AGENTS; close #29"
```
