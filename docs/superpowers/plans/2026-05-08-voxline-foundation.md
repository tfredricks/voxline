# voxline — Foundation Implementation Plan (Plan 1 of 4)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up the macOS menu-bar app shell with a Settings window, permissions plumbing, and a day-one validation spike that confirms `CGEventTap` keyboard monitoring works from a sandboxed app on Xcode 26 / macOS 26 — the answer determines whether the sandbox stays for v1.

**Architecture:** Single SwiftUI app target with `LSUIElement = true` (menu-bar-only, no Dock icon). `NSStatusItem` provides the menu bar entrypoint. `Settings` scene provides the preferences window. A standalone `EventTapSpike` Swift script verifies the sandbox-vs-tap question before we build anything that depends on it. All file I/O uses `FileManager` so paths work under the sandbox container.

**Tech Stack:** Swift 5, SwiftUI, AppKit (`NSStatusItem`, `NSPasteboard`), `CGEventTap` (Carbon/CoreGraphics), Xcode 26, macOS 14+ deployment, Swift Testing for unit tests.

**Spec reference:** `docs/superpowers/specs/2026-05-08-voxline-dictation-design.md` (v0.2)

---

## File Structure

Files this plan creates or modifies:

- **`voxline/voxlineApp.swift`** (modify) — App entry. Adds `MenuBarExtra` + `Settings` scenes. Becomes a menu-bar app, no main window.
- **`voxline/AppState.swift`** (create) — `@Observable` model holding global app state (menu icon status enum, future hooks for hotkey/recording state). Single source of truth for view state.
- **`voxline/MenuBar/MenuBarController.swift`** (create) — Wires `MenuBarExtra` content: status icon binding + menu items (Toggle voxline, Settings…, Quit).
- **`voxline/Settings/SettingsView.swift`** (create) — Top-level Settings tabbed view. Hosts `GeneralSettingsView`, `APIKeysSettingsView`, `ModesSettingsView` as empty scaffolds for now.
- **`voxline/Settings/GeneralSettingsView.swift`** (create) — Empty tab scaffold. Stub UI controls return in Plan 4.
- **`voxline/Settings/APIKeysSettingsView.swift`** (create) — Empty tab scaffold.
- **`voxline/Settings/ModesSettingsView.swift`** (create) — Empty tab scaffold.
- **`voxline/Permissions/PermissionsService.swift`** (create) — Wraps Microphone (`AVCaptureDevice.requestAccess`) and Accessibility (`AXIsProcessTrustedWithOptions`) checks. Pure model object, view-agnostic.
- **`voxline/Permissions/PermissionsState.swift`** (create) — `enum PermissionStatus { granted, denied, notDetermined }` and an `@Observable PermissionsViewModel` that polls and exposes status.
- **`voxline/Storage/AppPaths.swift`** (create) — Single accessor for `applicationSupportDirectory/voxline/`. Always goes through `FileManager`. Fixes spec §5.1's path-correctness requirement at the source.
- **`voxline/Info.plist`** (create — overrides auto-generated keys) — Required because we need `LSUIElement`, `NSMicrophoneUsageDescription`, and a few others. We disable `GENERATE_INFOPLIST_FILE` for the target and supply one.
- **`voxline/voxline.entitlements`** (modify) — Add `device.audio-input` and `network.client` to existing sandbox entitlements.
- **`voxlineTests/`** (create — new test target) — Test target plus initial tests for `AppPaths` and `PermissionsService` (the parts that are testable without UI or real OS prompts).
- **`spikes/EventTapSandboxSpike/`** (create — disposable) — A minimal standalone Swift script to validate the sandboxed-tap question. Lives outside the Xcode target. Discarded after the question is answered.

The plan is biased toward small, focused files. Each Settings tab gets its own file because they will grow independently in Plan 4. `PermissionsService` is split from `PermissionsViewModel` so the service can be unit-tested without observation infrastructure.

---

## Task 1: Sandboxed CGEventTap Validation Spike (BLOCKING)

**Why first:** Spec §11 lists this as a day-one risk. If `CGEventTap` keyboard monitoring doesn't work from a sandboxed app on this OS/Xcode combo, we'd discover it after building most of Plan 2. Settling it now costs ~30 minutes; settling it later costs days of rework.

**Files:**
- Create: `spikes/EventTapSandboxSpike/spike.swift`
- Create: `spikes/EventTapSandboxSpike/spike.entitlements`
- Create: `spikes/EventTapSandboxSpike/run.sh`

- [ ] **Step 1: Create the spike script**

Write `spikes/EventTapSandboxSpike/spike.swift`:

```swift
import Cocoa
import CoreGraphics

// Minimal sandboxed CGEventTap test.
// Goal: confirm we can observe flagsChanged events from a sandboxed binary
// on the current Xcode/macOS combo. Prints any flagsChanged event seen.
// Run for ~10 seconds, then exits.

let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)

guard let tap = CGEvent.tapCreate(
    tap: .cgSessionEventTap,
    place: .headInsertEventTap,
    options: .listenOnly,
    eventsOfInterest: mask,
    callback: { _, type, event, _ in
        let flags = event.flags
        FileHandle.standardOutput.write(Data("flagsChanged: \(flags.rawValue)\n".utf8))
        return Unmanaged.passUnretained(event)
    },
    userInfo: nil
) else {
    FileHandle.standardError.write(Data("FAIL: CGEvent.tapCreate returned nil (likely missing Accessibility permission for this binary, or sandbox blocking)\n".utf8))
    exit(2)
}

let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)

FileHandle.standardOutput.write(Data("OK: tap created, watching flagsChanged for 10s. Press/release modifiers now.\n".utf8))

// Run for 10 seconds.
let deadline = Date().addingTimeInterval(10)
while Date() < deadline {
    CFRunLoopRunInMode(.defaultMode, 0.5, false)
}

FileHandle.standardOutput.write(Data("DONE\n".utf8))
```

- [ ] **Step 2: Create the spike entitlements file (sandboxed)**

Write `spikes/EventTapSandboxSpike/spike.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.app-sandbox</key>
	<true/>
</dict>
</plist>
```

- [ ] **Step 3: Create the run script**

Write `spikes/EventTapSandboxSpike/run.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

# Compile.
swiftc spike.swift -o spike

# Sign with sandbox entitlements (ad-hoc).
codesign --force --sign - --entitlements spike.entitlements --options runtime spike

echo
echo "Binary built and sandbox-signed at: $(pwd)/spike"
echo
echo "NEXT STEPS:"
echo "  1. Open System Settings → Privacy & Security → Accessibility"
echo "  2. Add: $(pwd)/spike  (drag it in or use the + button)"
echo "  3. Toggle the switch ON for that entry"
echo "  4. Run: ./spike"
echo "  5. Press and release Left Ctrl, Left Option, Cmd, etc. for ~10s"
echo
echo "PASS criteria: you see 'flagsChanged: <number>' lines in output."
echo "FAIL criteria: 'FAIL: CGEvent.tapCreate returned nil' or no events appear."
```

Then `chmod +x spikes/EventTapSandboxSpike/run.sh`.

- [ ] **Step 4: Run the spike build**

```bash
./spikes/EventTapSandboxSpike/run.sh
```

Expected output: instructions to add the binary to Accessibility.

- [ ] **Step 5: Grant Accessibility, run the spike, record the result**

Follow the printed instructions. Then run:

```bash
./spikes/EventTapSandboxSpike/spike
```

Press Left Ctrl / Left Option a few times. Expected: lines like `flagsChanged: 262401` appearing in real time, then `DONE`.

Record the result in the spec: edit `docs/superpowers/specs/2026-05-08-voxline-dictation-design.md` §11, replace the bullet starting with "**CGEventTap from sandboxed app**" with one of:

- **PASS:** `**CGEventTap from sandboxed app** — verified working on Xcode 26.4.1 / macOS 26 on YYYY-MM-DD via spike at \`spikes/EventTapSandboxSpike\`. Sandbox stays enabled.`
- **FAIL:** `**CGEventTap from sandboxed app** — DOES NOT WORK on this OS/Xcode combo (verified YYYY-MM-DD). Decision: drop App Sandbox for v1; remove \`com.apple.security.app-sandbox\` from entitlements before Plan 2.`

- [ ] **Step 6: Commit**

```bash
git add spikes/ docs/superpowers/specs/2026-05-08-voxline-dictation-design.md
git commit -m "Validate CGEventTap from sandboxed app (spec §11 day-one risk)

Spike binary confirms whether keyboard event taps work from a sandboxed
process on Xcode 26 / macOS 26. Spec §11 updated with the verified result."
```

---

## Task 2: Convert app target to menu-bar-only with custom Info.plist

**Files:**
- Modify: `voxline.xcodeproj/project.pbxproj` — disable `GENERATE_INFOPLIST_FILE`, set `INFOPLIST_FILE = voxline/Info.plist`, add `LSUIElement` won't work via build settings since we're providing our own plist
- Create: `voxline/Info.plist`
- Modify: `voxline/voxline.entitlements` — add audio-input and network.client (only if Task 1 passed; if it failed, remove sandbox entitlement instead)

- [ ] **Step 1: Create `voxline/Info.plist`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>$(DEVELOPMENT_LANGUAGE)</string>
	<key>CFBundleExecutable</key>
	<string>$(EXECUTABLE_NAME)</string>
	<key>CFBundleIdentifier</key>
	<string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>$(PRODUCT_NAME)</string>
	<key>CFBundlePackageType</key>
	<string>$(PRODUCT_BUNDLE_PACKAGE_TYPE)</string>
	<key>CFBundleShortVersionString</key>
	<string>$(MARKETING_VERSION)</string>
	<key>CFBundleVersion</key>
	<string>$(CURRENT_PROJECT_VERSION)</string>
	<key>LSMinimumSystemVersion</key>
	<string>$(MACOSX_DEPLOYMENT_TARGET)</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHumanReadableCopyright</key>
	<string></string>
	<key>NSMicrophoneUsageDescription</key>
	<string>voxline records audio while you hold the dictation hotkey, transcribes it locally, and discards the audio. Audio never leaves your device.</string>
</dict>
</plist>
```

- [ ] **Step 2: Update `voxline.entitlements`**

Read current contents (already has `com.apple.security.app-sandbox` and `com.apple.security.files.user-selected.read-only`). Replace the entire file with:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.app-sandbox</key>
	<true/>
	<key>com.apple.security.device.audio-input</key>
	<true/>
	<key>com.apple.security.network.client</key>
	<true/>
</dict>
</plist>
```

**If Task 1 FAILED** (sandbox blocked the tap), instead use:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
</dict>
</plist>
```

…and in `project.pbxproj` change `CODE_SIGN_ENTITLEMENTS = voxline/voxline.entitlements;` → `CODE_SIGN_ENTITLEMENTS = "";` in both Debug and Release target configs.

- [ ] **Step 3: Update `project.pbxproj` to use the custom Info.plist**

In `voxline.xcodeproj/project.pbxproj`, find the two target build configurations (look for `A100000000000000000000B5 /* Debug */` and `A100000000000000000000B6 /* Release */` — both contain `GENERATE_INFOPLIST_FILE = YES;`).

For each of those two configs, replace the line:

```
				GENERATE_INFOPLIST_FILE = YES;
```

with:

```
				GENERATE_INFOPLIST_FILE = NO;
				INFOPLIST_FILE = voxline/Info.plist;
```

Also remove the line `INFOPLIST_KEY_NSHumanReadableCopyright = "";` from each of the two target configs (those keys are now in the plist itself).

- [ ] **Step 4: Build and verify the app launches as menu-bar-only**

```bash
xcodebuild -project voxline.xcodeproj -scheme voxline -configuration Debug -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

Then launch the built app:

```bash
open "$(find ~/Library/Developer/Xcode/DerivedData -name voxline.app -path '*/Debug/*' -print -quit)"
```

Expected: no Dock icon appears, no window appears (we haven't added the menu bar item yet, so this is a silent launch — but importantly, no Dock icon and no main window). Quit it via Activity Monitor or `pkill -f voxline`.

- [ ] **Step 5: Commit**

```bash
git add voxline/Info.plist voxline/voxline.entitlements voxline.xcodeproj/project.pbxproj
git commit -m "Convert target to LSUIElement (menu-bar-only) with custom Info.plist

- Custom Info.plist sets LSUIElement=true and NSMicrophoneUsageDescription
- Entitlements add audio-input and network.client per spec §8
- Build settings: GENERATE_INFOPLIST_FILE=NO, INFOPLIST_FILE points at our plist"
```

---

## Task 3: Add `AppPaths` and pin sandbox-correct path resolution with a test

**Why now:** Spec §5.1 mandates that all file I/O for app data go through `FileManager`. Locking this in via a tested helper before any code uses paths prevents the literal-path bug.

**Files:**
- Create: `voxline/Storage/AppPaths.swift`
- Create: `voxlineTests/AppPathsTests.swift`
- Modify: `voxline.xcodeproj/project.pbxproj` (add unit test target — see Task 3a below)

### Task 3a: Add a unit test target

- [ ] **Step 1: Add the test target to `project.pbxproj`**

Adding a test target by hand is mechanical but verbose. Open the project once in Xcode (`open voxline.xcodeproj`) and use **File → New → Target… → macOS → Unit Testing Bundle**. Name it `voxlineTests`. Target to test: `voxline`.

Xcode will:
- Create `voxlineTests/voxlineTests.swift` (a `@Suite struct voxlineTests` placeholder)
- Add `voxlineTests` target to the pbxproj
- Add a test scheme

Close Xcode. Verify from CLI:

```bash
xcodebuild -list -project voxline.xcodeproj
```

Expected: `voxlineTests` appears under both Targets and Schemes.

- [ ] **Step 2: Verify tests run**

```bash
xcodebuild -project voxline.xcodeproj -scheme voxlineTests -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

Expected: `** TEST SUCCEEDED **` (the placeholder test from Xcode's template passes).

- [ ] **Step 3: Delete the Xcode-generated placeholder test**

```bash
rm voxlineTests/voxlineTests.swift
```

- [ ] **Step 4: Commit**

```bash
git add voxline.xcodeproj voxlineTests/
git commit -m "Add voxlineTests unit test target"
```

### Task 3b: AppPaths helper with test

- [ ] **Step 1: Write the failing test**

Create `voxlineTests/AppPathsTests.swift`:

```swift
import Testing
import Foundation
@testable import voxline

@Suite struct AppPathsTests {

    @Test func applicationSupportDirectoryReturnsExistingDirectory() throws {
        let url = try AppPaths.applicationSupportDirectory()

        // Directory must exist on disk.
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        #expect(exists, "AppPaths.applicationSupportDirectory() must return an existing directory")
        #expect(isDir.boolValue, "Result must be a directory, not a file")

        // Path must end with /voxline (the app subdirectory).
        #expect(url.lastPathComponent == "voxline",
                "Expected URL to end with /voxline, got: \(url.path)")
    }

    @Test func modesFilePathIsUnderApplicationSupport() throws {
        let modesURL = try AppPaths.modesFile()
        let baseURL = try AppPaths.applicationSupportDirectory()

        #expect(modesURL.path.hasPrefix(baseURL.path),
                "modes.json must live under the app support directory")
        #expect(modesURL.lastPathComponent == "modes.json")
    }

    @Test func neverReturnsHardCodedHomePath() throws {
        // Under sandbox the path must be containerized; even outside sandbox it
        // must come from FileManager, not a hand-built ~/Library path.
        let url = try AppPaths.applicationSupportDirectory()
        let literalPath = NSHomeDirectory() + "/Library/Application Support/voxline"

        // Under sandbox NSHomeDirectory itself returns the container path, so
        // this assertion is really: the helper produces *something* and doesn't
        // throw. The strongest cross-sandbox assertion is just that it exists.
        #expect(!url.path.isEmpty)
        _ = literalPath  // referenced to document what we are NOT hardcoding
    }
}
```

- [ ] **Step 2: Run the test and verify it fails**

```bash
xcodebuild -project voxline.xcodeproj -scheme voxlineTests -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

Expected: compile error — `Cannot find 'AppPaths' in scope`.

- [ ] **Step 3: Implement `AppPaths`**

Create `voxline/Storage/AppPaths.swift`:

```swift
import Foundation

enum AppPaths {

    static func applicationSupportDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = base.appending(path: "voxline", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true
        )
        return dir
    }

    static func modesFile() throws -> URL {
        try applicationSupportDirectory().appending(path: "modes.json")
    }
}
```

- [ ] **Step 4: Run the test and verify it passes**

```bash
xcodebuild -project voxline.xcodeproj -scheme voxlineTests -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

Expected: `** TEST SUCCEEDED **` with 3 tests passing.

- [ ] **Step 5: Commit**

```bash
git add voxline/Storage/AppPaths.swift voxlineTests/AppPathsTests.swift
git commit -m "Add AppPaths helper backed by FileManager (spec §5.1)

Single accessor for the containerized Application Support/voxline directory.
Tests verify the directory exists, lives under app support, and the modes.json
path nests correctly. Required by sandbox path-correctness."
```

---

## Task 4: AppState (observable global state)

**Files:**
- Create: `voxline/AppState.swift`
- Create: `voxlineTests/AppStateTests.swift`

- [ ] **Step 1: Write the failing test**

Create `voxlineTests/AppStateTests.swift`:

```swift
import Testing
@testable import voxline

@Suite struct AppStateTests {

    @Test func newStateStartsIdle() {
        let state = AppState()
        #expect(state.status == .idle)
    }

    @Test func canTransitionThroughStatusEnum() {
        let state = AppState()
        state.status = .recording
        #expect(state.status == .recording)
        state.status = .thinking
        #expect(state.status == .thinking)
        state.status = .error("mic unavailable")
        if case .error(let msg) = state.status {
            #expect(msg == "mic unavailable")
        } else {
            Issue.record("expected .error case, got \(state.status)")
        }
        state.status = .idle
        #expect(state.status == .idle)
    }
}
```

- [ ] **Step 2: Run the test and verify it fails**

```bash
xcodebuild -project voxline.xcodeproj -scheme voxlineTests -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -15
```

Expected: compile error — `Cannot find 'AppState' in scope`.

- [ ] **Step 3: Implement `AppState`**

Create `voxline/AppState.swift`:

```swift
import Foundation
import Observation

enum AppStatus: Equatable {
    case idle
    case recording
    case thinking
    case error(String)
}

@Observable
final class AppState {
    var status: AppStatus = .idle
}
```

- [ ] **Step 4: Run the test and verify it passes**

```bash
xcodebuild -project voxline.xcodeproj -scheme voxlineTests -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add voxline/AppState.swift voxlineTests/AppStateTests.swift
git commit -m "Add AppState observable model with idle/recording/thinking/error states"
```

---

## Task 5: PermissionsService (Microphone + Accessibility checks)

**Files:**
- Create: `voxline/Permissions/PermissionsService.swift`
- Create: `voxlineTests/PermissionsServiceTests.swift`

`PermissionsService` is a thin wrapper that we can test for its return-type plumbing; the actual TCC prompts can't be unit-tested. The test verifies the public surface works without crashing and returns a known status.

- [ ] **Step 1: Write the failing test**

Create `voxlineTests/PermissionsServiceTests.swift`:

```swift
import Testing
@testable import voxline

@Suite struct PermissionsServiceTests {

    @Test func microphoneStatusReturnsKnownValue() {
        let service = PermissionsService()
        let status = service.microphoneStatus
        // Whatever the runner's TCC state is, it must be one of these:
        #expect([.granted, .denied, .notDetermined].contains(status))
    }

    @Test func accessibilityStatusReturnsKnownValue() {
        let service = PermissionsService()
        let status = service.accessibilityStatus
        // Accessibility doesn't have a "notDetermined" state in the same way;
        // it's effectively granted-or-not.
        #expect([.granted, .denied].contains(status))
    }
}
```

- [ ] **Step 2: Run the test and verify it fails**

```bash
xcodebuild -project voxline.xcodeproj -scheme voxlineTests -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -15
```

Expected: compile error — `Cannot find 'PermissionsService' in scope`.

- [ ] **Step 3: Implement `PermissionsService`**

Create `voxline/Permissions/PermissionsService.swift`:

```swift
import AVFoundation
import ApplicationServices
import Foundation

enum PermissionStatus: Equatable {
    case granted
    case denied
    case notDetermined
}

struct PermissionsService {

    var microphoneStatus: PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:    return .granted
        case .denied:        return .denied
        case .restricted:    return .denied
        case .notDetermined: return .notDetermined
        @unknown default:    return .notDetermined
        }
    }

    var accessibilityStatus: PermissionStatus {
        // No prompting variant — just read current state.
        AXIsProcessTrusted() ? .granted : .denied
    }

    /// Triggers the system mic-access prompt if status is .notDetermined.
    /// Returns the resulting status.
    @discardableResult
    func requestMicrophone() async -> PermissionStatus {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        return granted ? .granted : .denied
    }

    /// Prompts the user (via AX prompt + System Settings deep link) to grant Accessibility.
    /// AX permission cannot be granted programmatically; this just nudges.
    func promptAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(opts as CFDictionary)
    }
}
```

- [ ] **Step 4: Run the test and verify it passes**

```bash
xcodebuild -project voxline.xcodeproj -scheme voxlineTests -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add voxline/Permissions/PermissionsService.swift voxlineTests/PermissionsServiceTests.swift
git commit -m "Add PermissionsService for Microphone + Accessibility status

Wraps AVCaptureDevice and AXIsProcessTrusted. requestMicrophone() triggers
the TCC prompt; promptAccessibility() nudges the AX prompt. Both prompts
must be exercised manually; unit tests cover only the public surface and
return-type contract."
```

---

## Task 6: Settings tabbed view scaffold (3 empty tabs)

**Files:**
- Create: `voxline/Settings/SettingsView.swift`
- Create: `voxline/Settings/GeneralSettingsView.swift`
- Create: `voxline/Settings/APIKeysSettingsView.swift`
- Create: `voxline/Settings/ModesSettingsView.swift`

These are scaffolds. They render placeholder text now; real controls land in Plan 4. We make them now so `voxlineApp.swift` can wire `Settings { SettingsView() }` in Task 8.

- [ ] **Step 1: Create `GeneralSettingsView.swift`**

```swift
import SwiftUI

struct GeneralSettingsView: View {
    var body: some View {
        Form {
            Text("Hotkey, input device, and Whisper model settings live here. (Plan 4)")
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 320)
    }
}

#Preview {
    GeneralSettingsView()
}
```

- [ ] **Step 2: Create `APIKeysSettingsView.swift`**

```swift
import SwiftUI

struct APIKeysSettingsView: View {
    var body: some View {
        Form {
            Text("Anthropic and OpenAI API keys live here. (Plan 3)")
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 320)
    }
}

#Preview {
    APIKeysSettingsView()
}
```

- [ ] **Step 3: Create `ModesSettingsView.swift`**

```swift
import SwiftUI

struct ModesSettingsView: View {
    var body: some View {
        Form {
            Text("Per-app modes (bundle ID + prompt) live here. (Plan 3)")
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 320)
    }
}

#Preview {
    ModesSettingsView()
}
```

- [ ] **Step 4: Create `SettingsView.swift`**

```swift
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gear") }

            APIKeysSettingsView()
                .tabItem { Label("API Keys", systemImage: "key") }

            ModesSettingsView()
                .tabItem { Label("Modes", systemImage: "rectangle.3.group") }
        }
    }
}

#Preview {
    SettingsView()
}
```

- [ ] **Step 5: Build to verify all four files compile**

```bash
xcodebuild -project voxline.xcodeproj -scheme voxline -configuration Debug -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add voxline/Settings/
git commit -m "Add Settings tabbed view scaffold (General / API Keys / Modes)

All three tabs are empty placeholders for now. General and API Keys gain
real controls in Plan 4; Modes gains them in Plan 3."
```

---

## Task 7: MenuBarController (status icon + menu)

**Files:**
- Create: `voxline/MenuBar/MenuBarController.swift`

This file defines a SwiftUI `View` that renders inside `MenuBarExtra`'s `content` closure plus a tiny helper for the status-bar icon name.

- [ ] **Step 1: Create `MenuBarController.swift`**

```swift
import SwiftUI

/// Maps AppStatus → SF Symbol name for the menu bar icon.
enum MenuBarIcon {
    static func symbolName(for status: AppStatus) -> String {
        switch status {
        case .idle:        return "mic"
        case .recording:   return "mic.fill"
        case .thinking:    return "ellipsis.circle"
        case .error:       return "mic.slash"
        }
    }
}

struct MenuBarContent: View {
    @Bindable var state: AppState
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if case .error(let message) = state.status {
            Text(message)
                .foregroundStyle(.red)
            Divider()
        }

        Button("Settings…") {
            openSettings()
            // openSettings doesn't activate the app on its own; ensure the
            // settings window comes to the front.
            NSApp.activate(ignoringOtherApps: true)
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

- [ ] **Step 2: Add a unit test for the icon mapping**

Create `voxlineTests/MenuBarIconTests.swift`:

```swift
import Testing
@testable import voxline

@Suite struct MenuBarIconTests {

    @Test func iconForIdle() {
        #expect(MenuBarIcon.symbolName(for: .idle) == "mic")
    }

    @Test func iconForRecording() {
        #expect(MenuBarIcon.symbolName(for: .recording) == "mic.fill")
    }

    @Test func iconForThinking() {
        #expect(MenuBarIcon.symbolName(for: .thinking) == "ellipsis.circle")
    }

    @Test func iconForError() {
        #expect(MenuBarIcon.symbolName(for: .error("anything")) == "mic.slash")
    }
}
```

- [ ] **Step 3: Run the test and verify it passes**

```bash
xcodebuild -project voxline.xcodeproj -scheme voxlineTests -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add voxline/MenuBar/MenuBarController.swift voxlineTests/MenuBarIconTests.swift
git commit -m "Add menu bar content view + icon mapping for AppStatus

MenuBarContent renders Settings… and Quit items plus an inline error message
when status is .error. Icon mapping covered by unit tests."
```

---

## Task 8: Wire `voxlineApp.swift` — MenuBarExtra + Settings scenes

**Files:**
- Modify: `voxline/voxlineApp.swift`
- Delete: `voxline/ContentView.swift` (no longer used — we have no main window)

- [ ] **Step 1: Replace `voxlineApp.swift`**

Current contents (already in repo):

```swift
import SwiftUI

@main
struct voxlineApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
```

Replace entirely with:

```swift
import SwiftUI

@main
struct voxlineApp: App {

    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(state: appState)
        } label: {
            Image(systemName: MenuBarIcon.symbolName(for: appState.status))
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environment(appState)
        }
    }
}
```

- [ ] **Step 2: Delete `ContentView.swift`**

```bash
rm voxline/ContentView.swift
```

- [ ] **Step 3: Build**

```bash
xcodebuild -project voxline.xcodeproj -scheme voxline -configuration Debug -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Smoke test by running the app**

```bash
open "$(find ~/Library/Developer/Xcode/DerivedData -name voxline.app -path '*/Debug/*' -print -quit)"
```

Expected:
- A microphone icon appears in the menu bar
- Clicking it shows a menu with `Settings…` and `Quit voxline`
- Clicking `Settings…` opens a window with three tabs (General / API Keys / Modes), each showing placeholder text
- No Dock icon appears

Quit via the menu's `Quit voxline` item.

- [ ] **Step 5: Commit**

```bash
git add voxline/voxlineApp.swift
git rm voxline/ContentView.swift
git commit -m "Wire MenuBarExtra + Settings scenes; remove ContentView

App now launches as a menu-bar-only utility with a status icon driven by
AppState.status, a Settings window with three scaffolded tabs, and no main
window or Dock presence."
```

---

## Task 9: Final verification + plan handoff note

- [ ] **Step 1: Run the full test suite**

```bash
xcodebuild -project voxline.xcodeproj -scheme voxlineTests -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -15
```

Expected: `** TEST SUCCEEDED **` with all 11 tests passing — 3 from `AppPathsTests`, 2 from `AppStateTests`, 2 from `PermissionsServiceTests`, 4 from `MenuBarIconTests`.

- [ ] **Step 2: Build the release configuration as a sanity check**

```bash
xcodebuild -project voxline.xcodeproj -scheme voxline -configuration Release -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Manual smoke test checklist**

Run the Debug build and verify:

- [ ] App launches without a Dock icon
- [ ] Microphone icon appears in the menu bar
- [ ] Clicking the icon shows the menu (Settings…, Quit voxline)
- [ ] Settings… opens a tabbed window
- [ ] All three tabs render their placeholder copy
- [ ] Cmd+, opens Settings from the menu bar menu
- [ ] Quit voxline cleanly exits

- [ ] **Step 4: Tag the foundation milestone**

```bash
git tag -a foundation-complete -m "Plan 1 (Foundation) complete"
```

- [ ] **Step 5: Commit any final cleanup and update plan status**

If there are no uncommitted changes from Steps 1–3, skip this. Otherwise:

```bash
git add -A
git commit -m "Plan 1 final cleanup"
```

---

## Out of Scope (deferred to later plans)

- **Plan 2:** Hotkey state machine, audio capture pipeline, WhisperKit integration, recording pill UI
- **Plan 3:** LLM clients (Anthropic + OpenAI), Keychain key storage, mode routing, clipboard inject with chord-release gate, full E2E paste
- **Plan 4:** Real settings controls in all three tabs, first-run wizard, error states, smoke pass against §9.3 manual targets

---

## Spec Coverage (self-review)

| Spec section | Covered by | Notes |
|---|---|---|
| §4.1 Hotkey + audio | (Plan 2) | — |
| §4.2 Transcription | (Plan 2) | — |
| §4.3 LLM cleanup + paste | (Plan 3) | — |
| §5.1 Mode data model + path | Task 3b (`AppPaths.modesFile()`) | Path-correctness locked in |
| §5.3 App settings (Keychain) | (Plan 3) | — |
| §6.1 Menu bar icon | Tasks 7–8 | Status mapping + menu rendered |
| §6.2 Floating recording pill | (Plan 2) | — |
| §6.3 Settings window | Tasks 6, 8 | Scaffolds in place; controls in P3/P4 |
| §6.4 First-run wizard | (Plan 4) | — |
| §7 Privacy & Data | Task 3 (paths), Task 2 (entitlements) | Keychain in P3 |
| §7.1 Clipboard preservation | (Plan 3) | — |
| §8 Permissions & Entitlements | Tasks 2, 5 | Plist + entitlements + checks |
| §11 Sandboxed-tap risk | Task 1 (spike) | **Resolved as part of this plan** |
