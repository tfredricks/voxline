# Update Check Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire Sparkle 2 into voxline with a non-modal "gentle reminders" surface, dictation-aware deferral, and a CI release pipeline that ships notarized, EdDSA-signed DMGs plus an appcast feed.

**Architecture:** Sparkle 2 SPM dependency wrapped in a thin `UpdateService` class. A `DictationActivityMonitor` observes `AppState.status` to gate when reminders surface. Menu-bar shows a badge + "Install Update…" row when an update is pending; manual "Check for Updates…" always uses Sparkle's modal flow. A GitHub Actions workflow on `v*` tags builds, signs with Developer ID, notarizes, EdDSA-signs the DMG, regenerates `appcast.xml`, and publishes both to the GitHub Release and to a GitHub Pages branch.

**Tech Stack:** Swift / SwiftUI / AppKit; Sparkle 2.x; Xcode 16 / `xcodebuild`; GitHub Actions on `macos-15`; `notarytool`, `stapler`, Sparkle's `sign_update` and `generate_appcast`; GitHub Pages.

**Spec:** `docs/superpowers/specs/2026-05-20-update-check-design.md`

---

## File Map

**New files (Swift):**
- `voxline/Updates/UpdateService.swift` — wraps `SPUStandardUpdaterController`, exposes `checkForUpdates()`, `automaticallyChecksForUpdates`, `hasPendingUpdate`; implements `SPUStandardUserDriverDelegate` for gentle reminders and dictation-aware deferral.
- `voxline/Updates/DictationActivityMonitor.swift` — observes `AppState.status`; exposes `isActive: Bool` and `lastActivityAt: Date?`; computes `isWithinDeferralWindow(now:)`.

**New files (tests):**
- `voxlineTests/DictationActivityMonitorTests.swift`
- `voxlineTests/UpdateServiceTests.swift`

**Modified files (Swift / project):**
- `voxline.xcodeproj/project.pbxproj` — add Sparkle SPM dependency.
- `voxline/Info.plist` — add `SUFeedURL`, `SUPublicEDKey`, `SUEnableAutomaticChecks`, `SUScheduledCheckInterval`.
- `voxline/voxlineApp.swift` — instantiate `UpdateService` in `AppDelegate`; pass it into `MenuBarContent`.
- `voxline/MenuBar/MenuBarContent.swift` — add "Check for Updates…" item; conditionally add "Install Update…" row above it when `updateService.hasPendingUpdate == true`.
- `voxline/Settings/SettingsView.swift` — add "Software Updates" section with toggle.
- `voxline/Settings/GeneralSettingsViewModel.swift` — add `automaticallyChecksForUpdates: Bool` property and snapshot field; route through `UpdateService` (no `UserDefaults` write of our own — Sparkle stores it).

**New files (CI):**
- `.github/workflows/release.yml` — tag-triggered release pipeline.
- `.github/workflows/appcast-dryrun.yml` (new) — PR-only validation when `release.yml`, `Info.plist`, or the public key changes.

**New files (docs):**
- `docs/release/RELEASE.md` — one-time setup runbook (generating EdDSA keypair, provisioning secrets, configuring GitHub Pages) and per-release steps.

**One-time external work (not files in the repo):**
- Create `gh-pages` branch with an initial empty `appcast.xml`.
- Configure GitHub Pages to serve from `gh-pages` branch root.
- Provision GitHub Actions secrets: `APPLE_NOTARY_API_KEY_P8`, `APPLE_NOTARY_KEY_ID`, `APPLE_NOTARY_ISSUER_ID`, `DEVELOPER_ID_CERT_P12`, `DEVELOPER_ID_CERT_PASSWORD`, `SPARKLE_ED_PRIVATE_KEY`.

---

## Sparkle 2 API note

Sparkle 2's public API has small differences between point releases. When implementing tasks that touch the Sparkle delegate protocols, sanity-check the exact signatures against the version actually resolved by SPM by ⌥-clicking the symbol in Xcode. The code blocks below match Sparkle 2.6+. If a signature differs, adapt — the *shape* of the integration is what matters, not exact spelling.

---

### Task 1: Add Sparkle as a Swift Package dependency

**Files:**
- Modify: `voxline.xcodeproj/project.pbxproj`

This task is best done in Xcode UI rather than hand-editing the pbxproj — Xcode generates the boilerplate correctly. Verify after with a build.

- [ ] **Step 1: Open the project in Xcode**

```bash
open /Users/toddfredricks/GitHub/voxline/voxline.xcodeproj
```

- [ ] **Step 2: Add Sparkle package**

In Xcode: File → Add Package Dependencies… → enter URL:
```
https://github.com/sparkle-project/Sparkle
```
- Dependency Rule: **Up to Next Major Version**, starting from `2.6.0`.
- Add to target: `voxline`.
- Product to link: `Sparkle`.

- [ ] **Step 3: Confirm the pbxproj change**

Run: `git diff voxline.xcodeproj/project.pbxproj | head -60`

Expected: a new `XCRemoteSwiftPackageReference` for `Sparkle` and a new `XCSwiftPackageProductDependency` referencing it from the voxline target, alongside the existing `argmax-oss-swift` entries.

- [ ] **Step 4: Build to verify the dependency resolves**

Run:
```bash
xcodebuild -scheme voxline -configuration Debug -destination 'platform=macOS' build | xcbeautify
```
Expected: BUILD SUCCEEDED. Sparkle is downloaded and linked.

- [ ] **Step 5: Commit**

```bash
git add voxline.xcodeproj/project.pbxproj voxline.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
git commit -m "build: add Sparkle 2 SPM dependency"
```

---

### Task 2: Add Sparkle Info.plist keys (with placeholder EdDSA key)

**Files:**
- Modify: `voxline/Info.plist`

We add the keys now so the rest of the integration compiles and runs cleanly. The `SUPublicEDKey` will be a placeholder string for now; Task 8 generates the real keypair and replaces it.

- [ ] **Step 1: Read current Info.plist to find the insertion point**

Run:
```bash
grep -n "</dict>" voxline/Info.plist | tail -1
```
The keys go inside the top-level `<dict>`, just before its closing `</dict>`.

- [ ] **Step 2: Add the four Sparkle keys**

Insert the following block immediately before the final `</dict>` in `voxline/Info.plist`:

```xml
<key>SUFeedURL</key>
<string>https://tfredricks.github.io/voxline/appcast.xml</string>
<key>SUPublicEDKey</key>
<string>REPLACE_WITH_REAL_KEY_IN_TASK_8</string>
<key>SUEnableAutomaticChecks</key>
<true/>
<key>SUScheduledCheckInterval</key>
<integer>86400</integer>
```

- [ ] **Step 3: Validate the plist parses**

Run:
```bash
plutil -lint voxline/Info.plist
```
Expected: `voxline/Info.plist: OK`

- [ ] **Step 4: Build to verify**

Run:
```bash
xcodebuild -scheme voxline -configuration Debug -destination 'platform=macOS' build | xcbeautify
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add voxline/Info.plist
git commit -m "build: add Sparkle Info.plist keys (placeholder EdDSA key)"
```

---

### Task 3: Implement `DictationActivityMonitor` (test-first)

**Files:**
- Create: `voxline/Updates/DictationActivityMonitor.swift`
- Test: `voxlineTests/DictationActivityMonitorTests.swift`

Pure value-bearing class with no AppKit / Sparkle dependencies — testable in isolation. The monitor exposes:
- `isActive: Bool` — true while `AppState.status == .recording` or `.thinking`.
- `lastActivityAt: Date?` — the wall-clock time the monitor last saw a transition *into* `.recording` (rising edge) or *out of* `.thinking` (falling edge, i.e. dictation finished).
- `isWithinDeferralWindow(now:) -> Bool` — true if `isActive` OR `now - lastActivityAt < 120s`.

The 120s constant lives here as `static let deferralWindow: TimeInterval = 120`.

- [ ] **Step 1: Create the Updates directory**

Run:
```bash
mkdir -p voxline/Updates
```

- [ ] **Step 2: Write the failing tests**

Create `voxlineTests/DictationActivityMonitorTests.swift`:

```swift
import XCTest
@testable import voxline

@MainActor
final class DictationActivityMonitorTests: XCTestCase {

    func test_idleStatus_isNotActive_andDoesNotDefer() {
        let monitor = DictationActivityMonitor()
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        monitor.observe(status: .idle, at: now)
        XCTAssertFalse(monitor.isActive)
        XCTAssertNil(monitor.lastActivityAt)
        XCTAssertFalse(monitor.isWithinDeferralWindow(now: now))
    }

    func test_recordingStatus_isActive() {
        let monitor = DictationActivityMonitor()
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        monitor.observe(status: .recording, at: now)
        XCTAssertTrue(monitor.isActive)
        XCTAssertTrue(monitor.isWithinDeferralWindow(now: now))
    }

    func test_thinkingStatus_isActive() {
        let monitor = DictationActivityMonitor()
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        monitor.observe(status: .thinking, at: now)
        XCTAssertTrue(monitor.isActive)
        XCTAssertTrue(monitor.isWithinDeferralWindow(now: now))
    }

    func test_recordingThenIdle_setsLastActivityAt() {
        let monitor = DictationActivityMonitor()
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let t1 = t0.addingTimeInterval(5)
        monitor.observe(status: .recording, at: t0)
        monitor.observe(status: .idle, at: t1)
        XCTAssertFalse(monitor.isActive)
        XCTAssertEqual(monitor.lastActivityAt, t1)
    }

    func test_deferralWindowBoundaries() {
        let monitor = DictationActivityMonitor()
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
        monitor.observe(status: .recording, at: t0)
        monitor.observe(status: .idle, at: t0.addingTimeInterval(1))

        // Right at the boundary (119s after the .idle transition): still deferring.
        XCTAssertTrue(monitor.isWithinDeferralWindow(
            now: t0.addingTimeInterval(1 + 119)
        ))
        // 121s after the .idle transition: window has closed.
        XCTAssertFalse(monitor.isWithinDeferralWindow(
            now: t0.addingTimeInterval(1 + 121)
        ))
    }

    func test_deferralWindow_with_nilLastActivity_isFalse() {
        let monitor = DictationActivityMonitor()
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        XCTAssertFalse(monitor.isWithinDeferralWindow(now: now))
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run:
```bash
xcodebuild -scheme voxline -configuration Debug -destination 'platform=macOS' \
    -only-testing:voxlineTests/DictationActivityMonitorTests test | xcbeautify
```
Expected: FAILURE — `Cannot find 'DictationActivityMonitor' in scope`.

- [ ] **Step 4: Write the implementation**

Create `voxline/Updates/DictationActivityMonitor.swift`:

```swift
import Foundation
import Observation

@Observable
@MainActor
final class DictationActivityMonitor {

    static let deferralWindow: TimeInterval = 120

    private(set) var isActive: Bool = false
    private(set) var lastActivityAt: Date?

    func observe(status: AppStatus, at now: Date = .now) {
        let nowActive: Bool = {
            switch status {
            case .recording, .thinking: return true
            default: return false
            }
        }()

        // Falling edge — dictation just ended. Stamp the moment so the
        // deferral window starts counting from here.
        if isActive && !nowActive {
            lastActivityAt = now
        }
        // Rising edge — also stamp, so a still-in-flight session keeps the
        // window open even if status flips through unrelated states later.
        if !isActive && nowActive {
            lastActivityAt = now
        }
        isActive = nowActive
    }

    func isWithinDeferralWindow(now: Date = .now) -> Bool {
        if isActive { return true }
        guard let last = lastActivityAt else { return false }
        return now.timeIntervalSince(last) < Self.deferralWindow
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run:
```bash
xcodebuild -scheme voxline -configuration Debug -destination 'platform=macOS' \
    -only-testing:voxlineTests/DictationActivityMonitorTests test | xcbeautify
```
Expected: 6 tests pass.

- [ ] **Step 6: Commit**

```bash
git add voxline/Updates/DictationActivityMonitor.swift voxlineTests/DictationActivityMonitorTests.swift
git commit -m "feat(updates): add DictationActivityMonitor for update deferral"
```

---

### Task 4: Implement `UpdateService` skeleton (test-first)

**Files:**
- Create: `voxline/Updates/UpdateService.swift`
- Test: `voxlineTests/UpdateServiceTests.swift`

This task wires the Sparkle `SPUStandardUpdaterController` and exposes the surface the rest of the app needs. Dictation-aware deferral logic (the user-driver delegate methods) lands in Task 5 to keep this task focused.

- [ ] **Step 1: Write the failing tests**

Create `voxlineTests/UpdateServiceTests.swift`:

```swift
import XCTest
@testable import voxline

@MainActor
final class UpdateServiceTests: XCTestCase {

    /// Sanity: the wrapper can be constructed and exposes the documented
    /// public surface. (We don't drive Sparkle itself in unit tests —
    /// it's exercised end-to-end manually per the spec's testing section.)
    func test_construction_andPublicSurface() {
        let monitor = DictationActivityMonitor()
        let service = UpdateService(dictationActivity: monitor)

        // Toggleable through the wrapper, persists via Sparkle's UserDefaults.
        let original = service.automaticallyChecksForUpdates
        service.automaticallyChecksForUpdates = !original
        XCTAssertEqual(service.automaticallyChecksForUpdates, !original)
        service.automaticallyChecksForUpdates = original // restore

        // hasPendingUpdate defaults to false.
        XCTAssertFalse(service.hasPendingUpdate)

        // checkForUpdates() exists and is callable (does not crash).
        // We don't assert on Sparkle's network behavior here.
        service.checkForUpdates()
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:
```bash
xcodebuild -scheme voxline -configuration Debug -destination 'platform=macOS' \
    -only-testing:voxlineTests/UpdateServiceTests test | xcbeautify
```
Expected: FAILURE — `Cannot find 'UpdateService' in scope`.

- [ ] **Step 3: Write the implementation**

Create `voxline/Updates/UpdateService.swift`:

```swift
import AppKit
import Foundation
import Observation
import Sparkle

/// Thin wrapper around Sparkle's `SPUStandardUpdaterController`.
///
/// Owns the updater for the app's lifetime, surfaces a small Observable
/// API for SwiftUI bindings, and bridges Sparkle activity into voxline's
/// existing log pipeline.
@Observable
@MainActor
final class UpdateService: NSObject {

    /// Reflects whether a pending update has been deferred from the
    /// scheduled (gentle) path. Drives the menu-bar badge and the
    /// "Install Update…" row.
    private(set) var hasPendingUpdate: Bool = false

    var automaticallyChecksForUpdates: Bool {
        get { updaterController.updater.automaticallyChecksForUpdates }
        set { updaterController.updater.automaticallyChecksForUpdates = newValue }
    }

    private let dictationActivity: DictationActivityMonitor

    /// Cached most-recent appcast item Sparkle wants to show on the
    /// scheduled path, used so a menu click can re-enter Sparkle's modal.
    fileprivate var pendingAppcastItem: SUAppcastItem?

    /// Constructed lazily on first access so the `startingUpdater: true`
    /// argument does what it says — start Sparkle's scheduler once the
    /// delegate references are set.
    private lazy var updaterController: SPUStandardUpdaterController = {
        SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: self
        )
    }()

    init(dictationActivity: DictationActivityMonitor) {
        self.dictationActivity = dictationActivity
        super.init()
        _ = updaterController // force-init Sparkle now
    }

    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }
}

extension UpdateService: SPUUpdaterDelegate {
    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        AppLog.updates.error("update check aborted: \(error.localizedDescription)")
    }
}

// Gentle-reminders delegate methods land in Task 5.
extension UpdateService: SPUStandardUserDriverDelegate {}
```

You'll also need to add a `updates` category to `AppLog`:

In `voxline/Diagnostics/AppLog.swift`, add a line inside the `enum AppLog`:

```swift
static let updates     = Logger(subsystem: subsystem, category: "updates")
```

- [ ] **Step 4: Run the tests to verify they pass**

Run:
```bash
xcodebuild -scheme voxline -configuration Debug -destination 'platform=macOS' \
    -only-testing:voxlineTests/UpdateServiceTests test | xcbeautify
```
Expected: 1 test passes.

- [ ] **Step 5: Build the full target to surface any other issues**

Run:
```bash
xcodebuild -scheme voxline -configuration Debug -destination 'platform=macOS' build | xcbeautify
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Commit**

```bash
git add voxline/Updates/UpdateService.swift voxline/Diagnostics/AppLog.swift voxlineTests/UpdateServiceTests.swift
git commit -m "feat(updates): add UpdateService Sparkle wrapper skeleton"
```

---

### Task 5: Implement gentle-reminders mode + dictation-aware deferral

**Files:**
- Modify: `voxline/Updates/UpdateService.swift`
- Modify: `voxlineTests/UpdateServiceTests.swift` (add a deferral test that doesn't require Sparkle to fire)

This task adds the `SPUStandardUserDriverDelegate` methods that tell Sparkle to skip its modal for scheduled checks, hand voxline the appcast item, and re-enter Sparkle's modal flow on user request. Manual checks (which go through `SPUUpdater.checkForUpdates`) bypass this delegate path entirely — Sparkle uses its standard user driver UI for those.

> **Sparkle API note:** Sparkle 2.x calls `standardUserDriverShouldHandleShowingScheduledUpdate(_:andInImmediateFocus:)` to ask whether *Sparkle* should show the scheduled update. Returning `false` means we'll handle the presentation. The companion `standardUserDriverWillHandleShowingUpdate(_:forUpdate:state:)` is called when Sparkle is about to (or just decided not to) show the modal. Verify these exact spellings against the SPM-resolved Sparkle headers (⌥-click `SPUStandardUserDriverDelegate` in Xcode).

- [ ] **Step 1: Add a deferral-state test**

Append to `voxlineTests/UpdateServiceTests.swift`:

```swift
extension UpdateServiceTests {

    func test_shouldHandleScheduledUpdate_returnsFalse_alwaysGentle() {
        let monitor = DictationActivityMonitor()
        let service = UpdateService(dictationActivity: monitor)
        XCTAssertFalse(service.shouldSparkleHandleScheduledUpdateUI())
    }

    func test_canSurfaceGentleReminder_falseWhileDictating() {
        let monitor = DictationActivityMonitor()
        monitor.observe(status: .recording, at: .now)
        let service = UpdateService(dictationActivity: monitor)
        XCTAssertFalse(service.canSurfaceGentleReminder(now: .now))
    }

    func test_canSurfaceGentleReminder_falseWithinIdleWindow() {
        let monitor = DictationActivityMonitor()
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
        monitor.observe(status: .recording, at: t0)
        monitor.observe(status: .idle, at: t0.addingTimeInterval(1))
        let service = UpdateService(dictationActivity: monitor)
        XCTAssertFalse(service.canSurfaceGentleReminder(now: t0.addingTimeInterval(60)))
    }

    func test_canSurfaceGentleReminder_trueAfterIdleWindow() {
        let monitor = DictationActivityMonitor()
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
        monitor.observe(status: .recording, at: t0)
        monitor.observe(status: .idle, at: t0.addingTimeInterval(1))
        let service = UpdateService(dictationActivity: monitor)
        XCTAssertTrue(service.canSurfaceGentleReminder(now: t0.addingTimeInterval(1 + 121)))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:
```bash
xcodebuild -scheme voxline -configuration Debug -destination 'platform=macOS' \
    -only-testing:voxlineTests/UpdateServiceTests test | xcbeautify
```
Expected: FAILURE — methods `shouldSparkleHandleScheduledUpdateUI` and `canSurfaceGentleReminder` are not defined.

- [ ] **Step 3: Implement the delegate methods + surfacing helpers**

Replace the empty `extension UpdateService: SPUStandardUserDriverDelegate {}` in `voxline/Updates/UpdateService.swift` with:

```swift
extension UpdateService {
    /// Testable seam — independent of Sparkle types.
    /// Returns `false`: Sparkle should NOT use its modal UI for scheduled checks.
    func shouldSparkleHandleScheduledUpdateUI() -> Bool { false }

    /// Testable seam — true when the menu badge / "Install Update…" row
    /// is allowed to appear right now. (Once allowed, we set
    /// `hasPendingUpdate = true` and leave it there — the user dismisses
    /// it by clicking Install or by installing via Sparkle's modal.)
    func canSurfaceGentleReminder(now: Date = .now) -> Bool {
        !dictationActivity.isWithinDeferralWindow(now: now)
    }
}

extension UpdateService: SPUStandardUserDriverDelegate {

    /// Tell Sparkle we support gentle scheduled-update reminders.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Per-scheduled-check decision: should Sparkle itself drive the UI?
    /// We always answer "no" — voxline handles the presentation via the
    /// menu-bar badge, deferred around active dictation.
    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        shouldSparkleHandleScheduledUpdateUI()
    }

    /// Sparkle notifies us when it is about to (or just decided not to)
    /// present the standard UI for an update. We cache the item so a
    /// later menu-bar click can re-enter Sparkle's modal flow.
    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        if !handleShowingUpdate {
            pendingAppcastItem = update
            // Apply the deferral gate: only flip the visible badge once
            // dictation activity has settled. If we're inside the window,
            // poll back periodically until we can surface.
            tryRaisePendingFlag()
        }
    }

    /// Sparkle calls this once an update has been installed (or skipped
    /// permanently). Either way, our pending state is no longer valid.
    func standardUserDriverWillFinishUpdateSession() {
        pendingAppcastItem = nil
        hasPendingUpdate = false
    }
}

private extension UpdateService {
    func tryRaisePendingFlag() {
        if canSurfaceGentleReminder() {
            hasPendingUpdate = true
            return
        }
        // Try again in 30s. Cheap timer — the only state being polled is
        // a couple of Bool/Date reads.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            self?.tryRaisePendingFlag()
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run:
```bash
xcodebuild -scheme voxline -configuration Debug -destination 'platform=macOS' \
    -only-testing:voxlineTests/UpdateServiceTests test | xcbeautify
```
Expected: 5 tests pass (1 from Task 4 + 4 new).

- [ ] **Step 5: Build the full target**

Run:
```bash
xcodebuild -scheme voxline -configuration Debug -destination 'platform=macOS' build | xcbeautify
```
Expected: BUILD SUCCEEDED. If Sparkle's actual delegate signatures differ from what's used above, fix the spellings here before moving on.

- [ ] **Step 6: Commit**

```bash
git add voxline/Updates/UpdateService.swift voxlineTests/UpdateServiceTests.swift
git commit -m "feat(updates): gentle reminders + dictation-aware deferral"
```

---

### Task 6: Wire `UpdateService` into `AppDelegate` and observe `AppState.status`

**Files:**
- Modify: `voxline/voxlineApp.swift`

The `AppDelegate` already owns the `appState`. We add the `DictationActivityMonitor` and `UpdateService` to it, and install an `withObservationTracking` watcher (same pattern used for `state.hotkeyEnabled` and `state.toastMessage`) so `monitor.observe(status:)` fires on every status change.

- [ ] **Step 1: Add the new stored properties to `AppDelegate`**

In `voxline/voxlineApp.swift`, find the `AppDelegate` declaration:

```swift
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    let historyStore = DictationHistoryStore()
    let coordinator = AppCoordinator()
    let aboutWindow = AboutWindowController()
    let historyWindow = HistoryWindowController()
    let windowVisibility = WindowVisibilityCoordinator()
```

Add right below `windowVisibility`:

```swift
    let dictationActivity = DictationActivityMonitor()
    lazy var updateService = UpdateService(dictationActivity: dictationActivity)
```

- [ ] **Step 2: Start the activity observer in `applicationDidFinishLaunching`**

Replace the existing `applicationDidFinishLaunching` method:

```swift
    func applicationDidFinishLaunching(_ notification: Notification) {
        windowVisibility.start()
        coordinator.startIfNeeded(state: appState, historyStore: historyStore)
    }
```

with:

```swift
    func applicationDidFinishLaunching(_ notification: Notification) {
        windowVisibility.start()
        coordinator.startIfNeeded(state: appState, historyStore: historyStore)
        _ = updateService // force-init so Sparkle's scheduler starts
        observeStatusForUpdates()
    }

    /// Mirrors the `observeHotkeyEnabledChanges` / `observeToastChanges`
    /// pattern in `AppCoordinator`: each fire re-arms the tracker so we
    /// keep getting callbacks across the lifetime of the app.
    private func observeStatusForUpdates() {
        withObservationTracking {
            _ = appState.status
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.dictationActivity.observe(status: self.appState.status)
                self.observeStatusForUpdates()
            }
        }
        // Also seed the initial value.
        dictationActivity.observe(status: appState.status)
    }
```

- [ ] **Step 3: Build to verify**

Run:
```bash
xcodebuild -scheme voxline -configuration Debug -destination 'platform=macOS' build | xcbeautify
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add voxline/voxlineApp.swift
git commit -m "feat(updates): wire UpdateService and activity monitor in AppDelegate"
```

---

### Task 7: Add menu-bar items ("Check for Updates…" and conditional "Install Update…")

**Files:**
- Modify: `voxline/voxlineApp.swift` (pass `updateService` into `MenuBarContent`)
- Modify: `voxline/MenuBar/MenuBarContent.swift`

For the menu-bar badge itself: a small change in `MenuBarLabel` (in `voxlineApp.swift`) overlays a dot when `updateService.hasPendingUpdate == true`. SwiftUI's `Image(systemName:)` doesn't compose easily for badges, so we use a `ZStack` with a small filled circle anchored to the top-right.

- [ ] **Step 1: Update `MenuBarContent`'s call site to pass the service**

In `voxline/voxlineApp.swift`, find the `MenuBarExtra { MenuBarContent(...) }` invocation. Replace:

```swift
            MenuBarContent(
                state: delegate.appState,
                openAboutWindow: { ... },
                openHistoryWindow: { ... }
            )
```

with:

```swift
            MenuBarContent(
                state: delegate.appState,
                updateService: delegate.updateService,
                openAboutWindow: {
                    delegate.showAboutWindow()
                },
                openHistoryWindow: {
                    delegate.historyWindow.show(
                        store: delegate.historyStore,
                        state: delegate.appState
                    )
                }
            )
```

- [ ] **Step 2: Update `MenuBarLabel` to overlay the pending-update badge**

In `voxline/voxlineApp.swift`, replace the existing `MenuBarLabel`:

```swift
private struct MenuBarLabel: View {
    @Bindable var state: AppState
    var body: some View {
        Image(systemName: MenuBarIcon.symbolName(for: state.status, paused: !state.hotkeyEnabled))
    }
}
```

with:

```swift
private struct MenuBarLabel: View {
    @Bindable var state: AppState
    @Bindable var updateService: UpdateService
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: MenuBarIcon.symbolName(for: state.status, paused: !state.hotkeyEnabled))
            if updateService.hasPendingUpdate {
                Circle()
                    .fill(.blue)
                    .frame(width: 5, height: 5)
                    .offset(x: 2, y: -2)
                    .accessibilityLabel("Update available")
            }
        }
    }
}
```

And update the call site in the `MenuBarExtra { ... } label: { MenuBarLabel(state: delegate.appState) }` to pass `updateService:`:

```swift
        } label: {
            MenuBarLabel(state: delegate.appState, updateService: delegate.updateService)
        }
```

- [ ] **Step 3: Add the menu items in `MenuBarContent`**

In `voxline/MenuBar/MenuBarContent.swift`, replace the existing `struct MenuBarContent: View { ... }` definition with:

```swift
struct MenuBarContent: View {
    @Bindable var state: AppState
    @Bindable var updateService: UpdateService
    @Environment(\.openSettings) private var openSettings

    var openAboutWindow: () -> Void = {}
    var openHistoryWindow: () -> Void = {}

    var body: some View {
        if let message = state.status.errorMessage {
            Text(message)
                .foregroundStyle(.red)
            Divider()
        }

        if case .downloadingModel(let p) = state.status {
            Text("Downloading model — \(Int(p * 100))%")
                .foregroundStyle(.secondary)
            Divider()
        }

        if updateService.hasPendingUpdate {
            Button("Install update…") {
                updateService.checkForUpdates()
            }
            Divider()
        }

        Button(state.hotkeyEnabled ? "Pause Voxline" : "Resume Voxline") {
            state.hotkeyEnabled.toggle()
        }

        Divider()

        Button("Show history…") { openHistoryWindow() }

        Divider()

        Button("Settings…") {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
        .keyboardShortcut(",")

        Divider()

        Button("Check for updates…") {
            updateService.checkForUpdates()
        }

        Button("About Voxline") { openAboutWindow() }

        Divider()

        Button("Quit Voxline") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
```

> Note: the previous code had a `Divider()` before `About Voxline`. The new layout groups "Check for updates…" and "About Voxline" together (both meta items) without a divider between them, then a divider, then Quit. Confirm this grouping looks right in the running app at Step 4.

- [ ] **Step 4: Run the app and eyeball the menu**

Run:
```bash
xcodebuild -scheme voxline -configuration Debug -destination 'platform=macOS' build | xcbeautify
open /Users/toddfredricks/GitHub/voxline/build/Debug/voxline.app
```
(Or build/run from Xcode.)

Click the menu-bar icon. Expected:
- "Check for updates…" appears between Settings… and About Voxline.
- No badge on the icon (because nothing is pending yet).
- "Install Update…" does **not** appear (because `hasPendingUpdate == false`).

Quit the app when done.

- [ ] **Step 5: Build and run tests**

Run:
```bash
xcodebuild -scheme voxline -configuration Debug -destination 'platform=macOS' test | xcbeautify
```
Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add voxline/voxlineApp.swift voxline/MenuBar/MenuBarContent.swift
git commit -m "feat(updates): add menu-bar items and pending-update badge"
```

---

### Task 8: Generate EdDSA keypair, configure secrets, set up GitHub Pages

**Files:**
- Modify: `voxline/Info.plist` (replace placeholder `SUPublicEDKey`)
- Create: `docs/release/RELEASE.md`

This task is mostly out-of-repo configuration. It produces (a) a real public key baked into the app, (b) the private key stored as a GitHub Actions secret, and (c) a `gh-pages` branch serving an initial empty appcast. The repo deliverables are the new public key in `Info.plist` and a `RELEASE.md` runbook documenting the setup.

> **Critical:** The EdDSA private key is the *only* root of trust for "this update came from voxline's release pipeline". Lose it and you must rotate by baking a new public key into a new app version, which breaks the update path for all currently-deployed users (they keep validating against the old public key and reject the new feed entries). Back it up safely.

- [ ] **Step 1: Install Sparkle's generate_keys tool locally**

Sparkle ships `generate_keys` and `sign_update` as binaries inside the SPM-resolved Sparkle package, but the easiest local route is the official tar.gz release. Download Sparkle 2.6.x or later from `https://github.com/sparkle-project/Sparkle/releases` and extract `bin/generate_keys` and `bin/sign_update`. Place them somewhere on PATH (e.g. `/usr/local/bin`) or keep them in `~/voxline-sparkle-tools/`.

- [ ] **Step 2: Generate the EdDSA keypair**

Run (replace path with wherever you extracted the tools):
```bash
~/voxline-sparkle-tools/generate_keys
```
Expected output: a base64 public key on stdout, and the private key stored in your login keychain under the item `https://sparkle-project.org`. Copy the public key string verbatim.

- [ ] **Step 3: Export the private key for storage in GitHub Actions secrets**

Run:
```bash
~/voxline-sparkle-tools/generate_keys -x sparkle_ed_private.pem
```
This writes the private key to the file. Keep this file *out* of git (verify `git status` does not list it; add to a personal note / 1Password / similar). You'll paste its contents into the `SPARKLE_ED_PRIVATE_KEY` GitHub Actions secret in Step 5.

- [ ] **Step 4: Replace the placeholder `SUPublicEDKey` in `Info.plist`**

Edit `voxline/Info.plist` and replace:
```xml
<key>SUPublicEDKey</key>
<string>REPLACE_WITH_REAL_KEY_IN_TASK_8</string>
```
with:
```xml
<key>SUPublicEDKey</key>
<string>YOUR_BASE64_PUBLIC_KEY_FROM_STEP_2</string>
```

Validate:
```bash
plutil -lint voxline/Info.plist
```
Expected: `voxline/Info.plist: OK`

- [ ] **Step 5: Provision GitHub Actions secrets**

In the GitHub repo settings (`https://github.com/tfredricks/voxline/settings/secrets/actions`), add:

| Secret name | Value |
|---|---|
| `SPARKLE_ED_PRIVATE_KEY` | Contents of `sparkle_ed_private.pem` from Step 3 |
| `APPLE_NOTARY_KEY_ID` | Your App Store Connect API Key ID (e.g. `ABCDEF1234`) |
| `APPLE_NOTARY_ISSUER_ID` | Your App Store Connect issuer UUID |
| `APPLE_NOTARY_API_KEY_P8` | Contents of the `AuthKey_XXX.p8` file from App Store Connect |
| `DEVELOPER_ID_CERT_P12` | Base64-encoded `.p12` of your Developer ID Application cert: `base64 -i cert.p12 \| pbcopy` |
| `DEVELOPER_ID_CERT_PASSWORD` | Password used when exporting the `.p12` |

- [ ] **Step 6: Create the `gh-pages` branch with an initial empty appcast**

Run:
```bash
git checkout --orphan gh-pages
git rm -rf .
cat > appcast.xml <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>voxline</title>
    <link>https://tfredricks.github.io/voxline/appcast.xml</link>
    <description>voxline release feed</description>
    <language>en</language>
  </channel>
</rss>
EOF
git add appcast.xml
git commit -m "chore(pages): seed empty appcast"
git push origin gh-pages
git checkout main
```

Then in GitHub repo settings (`Settings → Pages`), set:
- Source: `Deploy from a branch`
- Branch: `gh-pages`, folder: `/ (root)`

Wait ~1 minute, then verify in browser:
```
https://tfredricks.github.io/voxline/appcast.xml
```
Expected: the empty-channel XML above.

- [ ] **Step 7: Write the release runbook**

Create `docs/release/RELEASE.md`:

```markdown
# Releasing voxline

## One-time setup (already done)

- EdDSA keypair generated via Sparkle's `generate_keys`. Public key lives in `voxline/Info.plist` as `SUPublicEDKey`. Private key stored in GitHub Actions secret `SPARKLE_ED_PRIVATE_KEY`. Backup copy of the private key lives in [PUT YOUR BACKUP LOCATION HERE].
- Developer ID Application cert exported as `.p12`, stored as `DEVELOPER_ID_CERT_P12` (base64) + `DEVELOPER_ID_CERT_PASSWORD` secrets.
- App Store Connect API key for notarization stored as `APPLE_NOTARY_API_KEY_P8` + `APPLE_NOTARY_KEY_ID` + `APPLE_NOTARY_ISSUER_ID`.
- `gh-pages` branch holds `appcast.xml`; GitHub Pages configured to serve from it.

## Per release

1. Bump `MARKETING_VERSION` in `voxline.xcodeproj/project.pbxproj` (Build Settings → Versioning) to the new version, e.g. `1.0.1`. Commit on `main`.
2. Tag the commit with a `v`-prefixed annotated tag whose message is the release notes:
   ```bash
   git tag -a v1.0.1 -m "$(cat <<'EOF'
   ## What's new in 1.0.1

   - ...
   EOF
   )"
   git push origin v1.0.1
   ```
3. GitHub Actions `release.yml` runs automatically:
   - builds the Release config, signs with Developer ID
   - notarizes via `notarytool` and staples
   - packages a DMG, EdDSA-signs it with `sign_update`
   - regenerates `appcast.xml` against the new DMG + tag-annotation notes
   - uploads the DMG to the GitHub Release for the tag
   - commits the updated `appcast.xml` to `gh-pages`
4. Watch the Action run. On success, verify:
   - `https://tfredricks.github.io/voxline/appcast.xml` contains a new `<item>` with the new version.
   - The DMG is attached to the GitHub Release for `v1.0.1`.
5. Run the manual test pass from `docs/release/MANUAL_TESTS.md` (see Task 11).

## Key rotation (only if EdDSA private key is lost or compromised)

This breaks updates for all currently-deployed users — they will reject feed entries signed with the new key. They must download the new version manually from the GitHub Release page. Plan accordingly.

1. Generate a new keypair: `generate_keys` (overwrites the keychain item).
2. Replace `SUPublicEDKey` in `voxline/Info.plist`.
3. Update the `SPARKLE_ED_PRIVATE_KEY` GitHub secret.
4. Cut a new release announcing the rotation in the notes.
```

- [ ] **Step 8: Commit**

```bash
git add voxline/Info.plist docs/release/RELEASE.md
git commit -m "build(updates): real EdDSA public key + release runbook"
```

---

### Task 9: Add the `release.yml` workflow

**Files:**
- Create: `.github/workflows/release.yml`

This is the biggest single artifact in the plan. Sequence: import certs into a temporary keychain → archive Release → notarize+staple → DMG → EdDSA-sign DMG → regenerate appcast → publish to gh-pages and GitHub Release.

We use `actions/checkout@v6` for consistency with `ci.yml`. We pull Sparkle's `sign_update` and `generate_appcast` from the SPM-resolved package's `Sparkle.framework/Resources/` (they ship inside the framework).

- [ ] **Step 1: Write the workflow file**

Create `.github/workflows/release.yml`:

```yaml
name: Release

on:
  push:
    tags:
      - 'v*'

permissions:
  contents: write  # to upload the DMG to the release and push to gh-pages

concurrency:
  group: release-${{ github.ref }}
  cancel-in-progress: false

jobs:
  build-and-publish:
    name: Build, sign, notarize, publish
    runs-on: macos-15
    timeout-minutes: 60
    env:
      KEYCHAIN_NAME: voxline-release.keychain
      KEYCHAIN_PASSWORD: ${{ github.run_id }}
    steps:
      - name: Checkout
        uses: actions/checkout@v6
        with:
          fetch-depth: 0

      - name: Select latest Xcode 16
        run: |
          XCODE=$(ls -d /Applications/Xcode_16*.app 2>/dev/null | sort -V | tail -1)
          if [[ -z "$XCODE" ]]; then
            echo "No Xcode 16.x found on runner" >&2
            exit 1
          fi
          sudo xcode-select -s "$XCODE"
          xcodebuild -version

      - name: Read version from tag
        id: ver
        run: |
          TAG="${GITHUB_REF##*/}"      # v1.0.1
          VERSION="${TAG#v}"            # 1.0.1
          BUILD="$(git rev-list --count HEAD)"
          echo "tag=$TAG"           >> "$GITHUB_OUTPUT"
          echo "version=$VERSION"   >> "$GITHUB_OUTPUT"
          echo "build=$BUILD"       >> "$GITHUB_OUTPUT"

      - name: Create temporary keychain
        run: |
          security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_NAME"
          security set-keychain-settings -lut 3600 "$KEYCHAIN_NAME"
          security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_NAME"
          # Make our keychain the default + prepend to the search list
          # so codesign can find the identity.
          security list-keychains -d user -s "$KEYCHAIN_NAME" \
            $(security list-keychains -d user | tr -d '"')
          security default-keychain -s "$KEYCHAIN_NAME"

      - name: Import Developer ID certificate
        env:
          CERT_B64: ${{ secrets.DEVELOPER_ID_CERT_P12 }}
          CERT_PWD: ${{ secrets.DEVELOPER_ID_CERT_PASSWORD }}
        run: |
          CERT_PATH="$RUNNER_TEMP/cert.p12"
          echo "$CERT_B64" | base64 --decode > "$CERT_PATH"
          security import "$CERT_PATH" \
            -k "$KEYCHAIN_NAME" \
            -P "$CERT_PWD" \
            -T /usr/bin/codesign \
            -T /usr/bin/security
          # Allow codesign to use the imported key without prompting.
          security set-key-partition-list \
            -S apple-tool:,apple:,codesign: \
            -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_NAME"
          rm "$CERT_PATH"

      - name: Write notarization API key
        env:
          NOTARY_KEY: ${{ secrets.APPLE_NOTARY_API_KEY_P8 }}
        run: |
          mkdir -p "$RUNNER_TEMP/notary"
          printf '%s' "$NOTARY_KEY" > "$RUNNER_TEMP/notary/AuthKey.p8"
          chmod 600 "$RUNNER_TEMP/notary/AuthKey.p8"

      - name: Resolve Swift packages
        run: |
          xcodebuild -resolvePackageDependencies \
            -scheme voxline \
            -project voxline.xcodeproj

      - name: Archive Release build
        run: |
          xcodebuild \
            -project voxline.xcodeproj \
            -scheme voxline \
            -configuration Release \
            -destination 'generic/platform=macOS' \
            -archivePath "$RUNNER_TEMP/voxline.xcarchive" \
            CURRENT_PROJECT_VERSION="${{ steps.ver.outputs.build }}" \
            MARKETING_VERSION="${{ steps.ver.outputs.version }}" \
            archive | xcbeautify

      - name: Export signed .app
        run: |
          cat > "$RUNNER_TEMP/exportOptions.plist" <<'EOF'
          <?xml version="1.0" encoding="UTF-8"?>
          <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
          <plist version="1.0">
          <dict>
            <key>method</key>
            <string>developer-id</string>
            <key>signingStyle</key>
            <string>automatic</string>
            <key>teamID</key>
            <string>2B5FBFV6CF</string>
          </dict>
          </plist>
          EOF
          xcodebuild \
            -exportArchive \
            -archivePath "$RUNNER_TEMP/voxline.xcarchive" \
            -exportPath "$RUNNER_TEMP/export" \
            -exportOptionsPlist "$RUNNER_TEMP/exportOptions.plist" | xcbeautify
          ls -la "$RUNNER_TEMP/export"

      - name: Notarize and staple
        run: |
          APP="$RUNNER_TEMP/export/voxline.app"
          ZIP="$RUNNER_TEMP/voxline.zip"
          /usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"
          xcrun notarytool submit "$ZIP" \
            --key "$RUNNER_TEMP/notary/AuthKey.p8" \
            --key-id "${{ secrets.APPLE_NOTARY_KEY_ID }}" \
            --issuer "${{ secrets.APPLE_NOTARY_ISSUER_ID }}" \
            --wait
          xcrun stapler staple "$APP"
          xcrun stapler validate "$APP"

      - name: Package DMG
        run: |
          brew install create-dmg
          APP="$RUNNER_TEMP/export/voxline.app"
          DMG="$RUNNER_TEMP/voxline-${{ steps.ver.outputs.version }}.dmg"
          create-dmg \
            --volname "voxline ${{ steps.ver.outputs.version }}" \
            --hdiutil-quiet \
            --no-internet-enable \
            --hide-extension voxline.app \
            "$DMG" \
            "$APP"
          ls -la "$DMG"

      - name: Locate Sparkle tools
        id: sparkle
        run: |
          # SPM resolves Sparkle into DerivedData; the framework bundles
          # sign_update and generate_appcast inside Sparkle.framework/Resources.
          SPARKLE_FRAMEWORK="$(find ~/Library/Developer/Xcode/DerivedData -type d -name 'Sparkle.framework' -path '*Build/Products/Release*' 2>/dev/null | head -1)"
          if [[ -z "$SPARKLE_FRAMEWORK" ]]; then
            SPARKLE_FRAMEWORK="$(find ~/Library/Developer/Xcode/DerivedData -type d -name 'Sparkle.framework' 2>/dev/null | head -1)"
          fi
          if [[ -z "$SPARKLE_FRAMEWORK" ]]; then
            echo "Sparkle.framework not found in DerivedData" >&2
            exit 1
          fi
          echo "framework=$SPARKLE_FRAMEWORK" >> "$GITHUB_OUTPUT"
          ls "$SPARKLE_FRAMEWORK/Resources" | grep -E 'sign_update|generate_appcast' || true

      - name: EdDSA-sign the DMG
        env:
          ED_KEY: ${{ secrets.SPARKLE_ED_PRIVATE_KEY }}
        run: |
          SIGN="${{ steps.sparkle.outputs.framework }}/Resources/sign_update"
          DMG="$RUNNER_TEMP/voxline-${{ steps.ver.outputs.version }}.dmg"
          # sign_update reads the private key from stdin when given -f -
          SIG="$(echo "$ED_KEY" | "$SIGN" -f /dev/stdin "$DMG")"
          echo "$SIG"   # Sample: sparkle:edSignature="..." length="..."
          echo "ed_signature_line=$SIG" >> "$GITHUB_ENV"

      - name: Checkout gh-pages
        uses: actions/checkout@v6
        with:
          ref: gh-pages
          path: gh-pages

      - name: Regenerate appcast
        run: |
          GEN="${{ steps.sparkle.outputs.framework }}/Resources/generate_appcast"
          # generate_appcast wants the private key + a directory of artifacts.
          # We place the DMG into a staging dir alongside an "updates" layout
          # it understands.
          STAGE="$RUNNER_TEMP/appcast-stage"
          mkdir -p "$STAGE"
          cp "$RUNNER_TEMP/voxline-${{ steps.ver.outputs.version }}.dmg" "$STAGE/"
          # Tag annotation message becomes the release notes HTML body.
          NOTES_HTML="$RUNNER_TEMP/release-notes.html"
          git for-each-ref refs/tags/${{ steps.ver.outputs.tag }} \
            --format='%(contents)' > "$RUNNER_TEMP/release-notes.md"
          # Cheap markdown → HTML; good enough for Sparkle's renderer.
          python3 -c "import markdown,sys; print(markdown.markdown(open('$RUNNER_TEMP/release-notes.md').read()))" \
            > "$NOTES_HTML" 2>/dev/null || cp "$RUNNER_TEMP/release-notes.md" "$NOTES_HTML"
          # Run generate_appcast with the env-supplied private key.
          echo "${{ secrets.SPARKLE_ED_PRIVATE_KEY }}" > "$RUNNER_TEMP/ed_key.pem"
          "$GEN" \
            --ed-key-file "$RUNNER_TEMP/ed_key.pem" \
            --download-url-prefix "https://github.com/tfredricks/voxline/releases/download/${{ steps.ver.outputs.tag }}/" \
            --release-notes-url-prefix "https://tfredricks.github.io/voxline/notes/" \
            -o "$RUNNER_TEMP/new-appcast.xml" \
            "$STAGE"
          rm "$RUNNER_TEMP/ed_key.pem"

          # Validate the generated appcast is well-formed and has an
          # enclosure with a non-empty sparkle:edSignature.
          xmllint --noout "$RUNNER_TEMP/new-appcast.xml"
          grep -q 'sparkle:edSignature="..*"' "$RUNNER_TEMP/new-appcast.xml" \
            || { echo "appcast missing edSignature" >&2; exit 1; }

          # Replace gh-pages appcast and also place the release notes HTML
          # under notes/<version>.html so Sparkle can fetch it via the
          # --release-notes-url-prefix above.
          cp "$RUNNER_TEMP/new-appcast.xml" gh-pages/appcast.xml
          mkdir -p "gh-pages/notes"
          cp "$NOTES_HTML" "gh-pages/notes/${{ steps.ver.outputs.version }}.html"

      - name: Publish appcast to gh-pages
        run: |
          cd gh-pages
          git config user.name  "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"
          git add appcast.xml notes/
          if git diff --cached --quiet; then
            echo "No appcast changes to publish."
          else
            git commit -m "release: appcast for ${{ steps.ver.outputs.tag }}"
            git push origin gh-pages
          fi

      - name: Upload DMG to the GitHub Release
        uses: softprops/action-gh-release@v2
        with:
          tag_name: ${{ steps.ver.outputs.tag }}
          files: |
            ${{ runner.temp }}/voxline-${{ steps.ver.outputs.version }}.dmg
          body_path: ${{ runner.temp }}/release-notes.md
          fail_on_unmatched_files: true

      - name: Clean up keychain
        if: always()
        run: |
          security default-keychain -s login.keychain || true
          security delete-keychain "$KEYCHAIN_NAME" || true
          rm -f "$RUNNER_TEMP/notary/AuthKey.p8" || true
```

- [ ] **Step 2: Sanity-check the workflow with `actionlint`**

Run (install if missing: `brew install actionlint`):
```bash
actionlint .github/workflows/release.yml
```
Expected: no errors. Warnings about external actions are OK.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/release.yml
git commit -m "ci: add release workflow (sign, notarize, EdDSA, appcast publish)"
```

---

### Task 10: Add appcast dry-run validation to PRs

**Files:**
- Create: `.github/workflows/appcast-dryrun.yml`

This job runs on every PR that touches `release.yml`, `Info.plist`, or the public-key entry — it builds with a dummy cert path, generates an appcast against a fixture DMG, and validates the resulting XML. Catches "the appcast generator started silently emitting empty signatures" before it ships.

The dummy DMG is a 1KB file with the right name — `generate_appcast` reads version metadata from the embedded `Info.plist`, so we use a real (cached) `voxline.app` if available, falling back to skipping the signature check when it isn't.

- [ ] **Step 1: Write the workflow**

Create `.github/workflows/appcast-dryrun.yml`:

```yaml
name: Appcast dry-run

on:
  pull_request:
    paths:
      - '.github/workflows/release.yml'
      - '.github/workflows/appcast-dryrun.yml'
      - 'voxline/Info.plist'

permissions:
  contents: read

concurrency:
  group: appcast-dryrun-${{ github.ref }}
  cancel-in-progress: true

jobs:
  validate:
    runs-on: macos-15
    timeout-minutes: 20
    steps:
      - uses: actions/checkout@v6

      - name: Select latest Xcode 16
        run: |
          XCODE=$(ls -d /Applications/Xcode_16*.app 2>/dev/null | sort -V | tail -1)
          sudo xcode-select -s "$XCODE"

      - name: Resolve Swift packages
        run: |
          xcodebuild -resolvePackageDependencies \
            -scheme voxline \
            -project voxline.xcodeproj

      - name: Debug-build the app (so we have a real .app to test with)
        run: |
          xcodebuild \
            -project voxline.xcodeproj \
            -scheme voxline \
            -configuration Debug \
            -destination 'platform=macOS' \
            -derivedDataPath "$RUNNER_TEMP/DerivedData" \
            build | xcbeautify

      - name: Generate throwaway EdDSA key
        id: keys
        run: |
          SPARKLE_FRAMEWORK="$(find "$RUNNER_TEMP/DerivedData" -type d -name 'Sparkle.framework' | head -1)"
          GEN_KEYS="$SPARKLE_FRAMEWORK/Resources/generate_keys"
          if [[ -x "$GEN_KEYS" ]]; then
            "$GEN_KEYS" -x "$RUNNER_TEMP/dummy_ed.pem"
          else
            # Fall back: synthesize a valid ed25519 key with openssl.
            openssl genpkey -algorithm ed25519 -out "$RUNNER_TEMP/dummy_ed.pem"
          fi
          echo "framework=$SPARKLE_FRAMEWORK" >> "$GITHUB_OUTPUT"

      - name: Package a throwaway DMG
        run: |
          APP="$(find "$RUNNER_TEMP/DerivedData" -type d -name 'voxline.app' -path '*Build/Products/Debug/*' | head -1)"
          brew install create-dmg
          create-dmg \
            --volname "voxline dryrun" \
            --hdiutil-quiet \
            --no-internet-enable \
            "$RUNNER_TEMP/voxline-dryrun.dmg" \
            "$APP"

      - name: Run generate_appcast against the dummy DMG
        run: |
          GEN="${{ steps.keys.outputs.framework }}/Resources/generate_appcast"
          STAGE="$RUNNER_TEMP/stage"
          mkdir -p "$STAGE"
          cp "$RUNNER_TEMP/voxline-dryrun.dmg" "$STAGE/"
          "$GEN" \
            --ed-key-file "$RUNNER_TEMP/dummy_ed.pem" \
            --download-url-prefix "https://example.invalid/" \
            -o "$RUNNER_TEMP/dryrun-appcast.xml" \
            "$STAGE"

      - name: Validate appcast
        run: |
          xmllint --noout "$RUNNER_TEMP/dryrun-appcast.xml"
          # Must contain at least one <enclosure> with a non-empty edSignature.
          grep -q 'sparkle:edSignature="..*"' "$RUNNER_TEMP/dryrun-appcast.xml" \
            || { echo "ERROR: appcast missing edSignature" >&2; cat "$RUNNER_TEMP/dryrun-appcast.xml" >&2; exit 1; }
          echo "Appcast dry-run passed."
```

- [ ] **Step 2: Lint**

Run:
```bash
actionlint .github/workflows/appcast-dryrun.yml
```
Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/appcast-dryrun.yml
git commit -m "ci: add appcast dry-run validation on PRs"
```

---

### Task 11: Settings UI — "Software Updates" section with toggle

**Files:**
- Modify: `voxline/voxlineApp.swift` (inject `UpdateService` into the Settings scene)
- Modify: `voxline/Settings/SettingsView.swift`

The simplest wiring is to read/write `UpdateService.automaticallyChecksForUpdates` directly from `SettingsView` via an `@Environment` injection. Sparkle owns the underlying `UserDefaults` storage; routing through `GeneralSettingsViewModel` / `AppSettings` would only add ceremony without buying anything.

- [ ] **Step 1: Inject `UpdateService` into the Settings scene**

In `voxline/voxlineApp.swift`, find:

```swift
        Settings {
            SettingsView(
                generalVM: GeneralSettingsViewModel(onApply: { [weak coordinator = delegate.coordinator] snapshot in
                    coordinator?.apply(snapshot)
                }),
                apiKeysVM: APIKeysSettingsViewModel()
            )
            .environment(delegate.appState)
        }
```

Change to:

```swift
        Settings {
            SettingsView(
                generalVM: GeneralSettingsViewModel(onApply: { [weak coordinator = delegate.coordinator] snapshot in
                    coordinator?.apply(snapshot)
                }),
                apiKeysVM: APIKeysSettingsViewModel()
            )
            .environment(delegate.appState)
            .environment(delegate.updateService)
        }
```

- [ ] **Step 2: Add the Software Updates section to `SettingsView`**

In `voxline/Settings/SettingsView.swift`, near the top of the file add:

```swift
@Environment(UpdateService.self) private var updateService
```

— place it alongside the other `@Environment` / `@State` declarations.

Then, inside the `Form { ... }` body (after the existing `Section("Startup")` block, or at the end, your call), insert:

```swift
                    Section("Software Updates") {
                        @Bindable var updateService = updateService
                        Toggle("Automatically check for updates",
                               isOn: $updateService.automaticallyChecksForUpdates)
                        Text("Voxline checks once a day in the background and shows a small badge on the menu-bar icon when an update is ready. Click \"Check for updates…\" in the menu to check manually.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
```

- [ ] **Step 3: Build and run the app**

Run:
```bash
xcodebuild -scheme voxline -configuration Debug -destination 'platform=macOS' build | xcbeautify
```
Expected: BUILD SUCCEEDED.

Open the app, open Settings, confirm:
- A "Software Updates" section is present.
- The toggle reads the current default (`YES` on first run from `SUEnableAutomaticChecks`).
- Toggling it off and reopening Settings shows it stays off (Sparkle's UserDefaults persistence).

- [ ] **Step 4: Run all tests**

Run:
```bash
xcodebuild -scheme voxline -configuration Debug -destination 'platform=macOS' test | xcbeautify
```
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add voxline/voxlineApp.swift voxline/Settings/SettingsView.swift
git commit -m "feat(updates): add Software Updates settings section"
```

---

### Task 12: Manual end-to-end test checklist

**Files:**
- Create: `docs/release/MANUAL_TESTS.md`

Documents the manual test pass to run before each release until the workflow has been exercised enough that we trust it. No code changes.

- [ ] **Step 1: Write the doc**

Create `docs/release/MANUAL_TESTS.md`:

```markdown
# Manual test pass: update check

Run this checklist after the release workflow succeeds and before announcing the release.

## Setup

You'll need two installed copies of voxline:
- The *previous* released version (the one users are currently on).
- A debug build pointed at a *staging* appcast you control, for the tamper test.

Configure a staging appcast by setting `SUFeedURL` in a debug build's `Info.plist` to a file URL or a private Pages branch.

## End-to-end happy path

- [ ] Launch the previous release. Confirm `Settings → Software Updates` shows "Automatically check for updates" enabled.
- [ ] Force a scheduled check: from the menu, click "Check for updates…".
- [ ] Sparkle's modal appears, says a new version is available, shows the release notes from the appcast.
- [ ] Click Install. Sparkle downloads from the GitHub Release URL, verifies the EdDSA signature, replaces the app, relaunches.
- [ ] The new version launches without a Gatekeeper warning. Confirm via `mdls -name kMDItemContentTypeTree /Applications/voxline.app | grep apple.application` and `spctl -a -v /Applications/voxline.app` (expected: `accepted source=Notarized Developer ID`).
- [ ] Settings (Software Updates toggle, hotkey, model, API keys) survived the swap.

## Gentle reminder UI

- [ ] With a known pending update on the staging feed, leave voxline running idle for >24h (or temporarily reduce `SUScheduledCheckInterval` to ~120s in a debug build for testing).
- [ ] Confirm: no modal appears. A small blue dot appears on the menu-bar icon. The menu contains an "Install Update…" row near the top.
- [ ] Click "Install Update…". Sparkle's modal appears (the user explicitly asked).

## Dictation-aware deferral

- [ ] With a pending update on the staging feed, start a dictation (hold the hotkey, speak).
- [ ] Mid-dictation, confirm the menu-bar badge does NOT appear and no Sparkle UI surfaces.
- [ ] Release the hotkey. Wait until the cleaned text is pasted and `state.status` returns to `.idle`.
- [ ] Within 2 minutes, do another dictation. Confirm the badge still does NOT appear (the idle window is reset).
- [ ] Wait 2+ minutes idle. Confirm the badge appears.
- [ ] Separately: with a pending update, start a dictation and click "Check for Updates…" from the menu. Confirm Sparkle's modal DOES appear — manual checks bypass the deferral (this is intentional).

## Tamper test

- [ ] In the staging appcast, edit one byte of the `sparkle:edSignature` attribute on the latest `<item>`.
- [ ] Trigger a check from the previous release. Sparkle attempts to install, then aborts with a signature error.
- [ ] Confirm the failure shows up in logs: `scripts/tail-logs.sh` includes a line tagged `[updates]` describing the abort.

## Network failure

- [ ] Disable network. Click "Check for updates…". Sparkle reports an error dialog. App keeps running.
- [ ] Re-enable network. Click "Check for updates…". Normal flow resumes.
```

- [ ] **Step 2: Commit**

```bash
git add docs/release/MANUAL_TESTS.md
git commit -m "docs(updates): manual end-to-end test checklist"
```

---

## Final verification

After all tasks are merged, before cutting the first real release tag:

- [ ] Confirm `Info.plist` has a real `SUPublicEDKey` (not the placeholder).
- [ ] Confirm GitHub Pages is serving the empty `appcast.xml` at `https://tfredricks.github.io/voxline/appcast.xml`.
- [ ] Confirm all six GitHub Actions secrets are present.
- [ ] Cut a test release tag (`v1.0.0-rc1` or similar) and watch the workflow run end-to-end. If it succeeds, fine. If not, debug and iterate before promoting to `v1.0.0`.
- [ ] After `v1.0.0` ships: install it on a clean Mac, wait for a `v1.0.1` to publish, and verify a real user would receive the update via the gentle-reminder path. (This is the only test we can't do until two releases exist.)
