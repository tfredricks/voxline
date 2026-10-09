# Platform Reset (0.4.0) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship voxline 0.4.0 as an unsandboxed app on macOS 26 that behaves exactly like 0.3.1, migrates existing users' data out of the sandbox container, deletes the sandbox workarounds, and records per-dictation latency metrics so phase 2 can be measured against a baseline.

**Architecture:** Remove the App Sandbox entitlement and bump the deployment target; everything else follows from paths and AX reads now working. `AppPaths` becomes the single owner of every on-disk location and `ContainerMigration` moves 0.3.x data on first launch. The paste-eligibility shims in `ClipboardInjector` are deleted, a process-wide AX messaging timeout is installed, and the selection reader goes AX-first with the synthetic Cmd+C as a fallback. `DictationMetricsStore` captures timings from `CapturePipeline` and surfaces them in the About window; history keeps the raw transcript.

**Tech Stack:** Swift (language mode 5 with the codebase's strict-concurrency patterns: `@MainActor` types, `Sendable` protocols), SwiftUI + AppKit, WhisperKit 1.0 via SPM, Swift Testing (`@Suite` / `@Test` / `#expect` / `#require` — never XCTest), Xcode 26, `xcodebuild`.

**Spec:** Phase 1 section of `docs/superpowers/specs/2026-10-08-voxline-roadmap-design.md`.

## Global Constraints

- Minimum macOS becomes **26.0** (`MACOSX_DEPLOYMENT_TARGET = 26.0` in every configuration of both targets). Was 14.0.
- The app is **not sandboxed** after Task 1. Keep hardened runtime (`ENABLE_HARDENED_RUNTIME = YES`), keep `com.apple.security.device.audio-input`, keep `keychain-access-groups` with `$(AppIdentifierPrefix)com.voxline.app`. Nothing else in the entitlements file.
- Bundle ID stays `com.voxline.app`; keychain service ID stays `com.voxline.app.keys`; all existing `UserDefaults` keys keep their names.
- App data root is `~/Library/Application Support/voxline/` (`modes.json`, `huggingface/` model cache). Preferences live in the standard defaults domain.
- Tests use Swift Testing. Per-test `UserDefaults(suiteName:)` and temp directories; never touch `UserDefaults.standard` or the real keychain from a test.
- Run one suite with: `xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/<SuiteName>` (don't pipe through xcbeautify unless you `set -o pipefail` first). Full suite: drop `-only-testing`.
- Commits go directly on `main`, Conventional Commits, DCO sign-off (`git commit -s`), and end the message with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- No narrating comments. Doc comments (`///`) only on behavior contracts.
- The Xcode project uses synchronized folders (`PBXFileSystemSynchronizedRootGroup`): new `.swift` files under `voxline/` or `voxlineTests/` are picked up automatically. Never edit `project.pbxproj` to add files.

---

## File structure

| File | Responsibility | Task |
|---|---|---|
| `voxline/voxline.entitlements` | Hardened-runtime entitlements only | 1 |
| `voxline/Info.plist` | Drop the sandbox-only Sparkle launcher flag | 1 |
| `voxline.xcodeproj/project.pbxproj` | Deployment target 26.0; version 0.4.0 at the end | 1, 12 |
| `.github/workflows/ci.yml`, `release.yml` | macOS 26 runners, Xcode 26 | 1 |
| `voxline/AppCoordinator.swift` (new) | `AppCoordinator`, moved verbatim out of `voxlineApp.swift` | 2 |
| `voxline/voxlineApp.swift` | App entry + `AppDelegate` only; wiring for migration, metrics, selection reader | 2, 4, 6, 9 |
| `voxline/Storage/AppPaths.swift` | Every on-disk path, including the legacy container | 3 |
| `voxline/Transcription/TranscriptionService.swift` | WhisperKit `downloadBase` under Application Support | 3 |
| `voxline/Storage/ContainerMigration.swift` (new) | One-shot move of 0.3.x container data | 4 |
| `voxline/Util/AXMessagingTimeout.swift` (new) | Process-wide AX request timeout | 5 |
| `voxline/Output/ClipboardInjector.swift` | Delete paste-eligibility shims | 5 |
| `voxline/Util/AXAttributeReading.swift` | Doc comment no longer mentions the menu walk | 5 |
| `voxline/Context/AXSelectionReader.swift` (new) | AX-first selection read, Cmd+C fallback | 6 |
| `voxline/Context/SelectionSnapshot.swift` | Doc comment: now the fallback | 6 |
| `voxline/Modes/FocusedField.swift` | `isEditable` | 7 |
| `voxline/Pipeline/CapturePipeline.swift` | No-field path, raw transcript, metrics | 7, 8, 9 |
| `voxline/Pipeline/PipelineProtocols.swift` | `Transcribing.engineID` | 9 |
| `voxline/Storage/DictationHistoryStore.swift`, `voxline/UI/HistoryView.swift` | Raw transcript column | 8 |
| `voxline/Diagnostics/DictationMetrics.swift` (new), `voxline/Diagnostics/AppLog.swift` | Metrics record + store + log category | 9 |
| `voxline/UI/DiagnosticsView.swift` (new), `AboutView.swift`, `AboutWindowController.swift` | Diagnostics in About | 9 |
| `voxline/Storage/DataProtectionKeychain.swift`, `voxline/Settings/APIKeysSettingsViewModel.swift` | Read errors are errors; never delete over one | 10 |
| `scripts/reset-local-state.sh`, `scripts/tail-logs.sh` | New paths, new log category | 11 |
| `README.md`, `AGENTS.md`, `CHANGELOG.md`, `docs/release/MANUAL_TESTS.md` | Docs | 1, 11, 12 |
| Tests: `AppPathsTests`, `ContainerMigrationTests`, `AXSelectionReaderTests`, `DictationMetricsStoreTests` (new); `FocusedFieldTests`, `CapturePipelineTests`, `DictationHistoryStoreTests`, `APIKeysSettingsViewModelTests`, `WizardViewModelTests`, `InMemoryKeychain` (modified) | | 3–10 |

---

### Task 1: Entitlements, deployment target, CI runners

**Files:**
- Modify: `voxline/voxline.entitlements`
- Modify: `voxline/Info.plist`
- Modify: `voxline.xcodeproj/project.pbxproj` (four `MACOSX_DEPLOYMENT_TARGET` lines)
- Modify: `.github/workflows/ci.yml`, `.github/workflows/release.yml`
- Modify: `README.md` (lines 11, 15, 95, 98), `AGENTS.md` (build/test paragraph)

**Interfaces:**
- Consumes: nothing.
- Produces: an unsandboxed, macOS-26-only build. Every later task assumes AX reads of other apps work.

- [ ] **Step 1: Replace the entitlements file**

Write `voxline/voxline.entitlements` as exactly:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.device.audio-input</key>
	<true/>
	<key>keychain-access-groups</key>
	<array>
		<string>$(AppIdentifierPrefix)com.voxline.app</string>
	</array>
</dict>
</plist>
```

- [ ] **Step 2: Drop the sandbox-only Sparkle flag from Info.plist**

Delete these two lines from `voxline/Info.plist` (Sparkle's installer-launcher XPC service exists only for sandboxed apps):

```xml
	<key>SUEnableInstallerLauncherService</key>
	<true/>
```

- [ ] **Step 3: Bump the deployment target**

```bash
sed -i '' 's/MACOSX_DEPLOYMENT_TARGET = 14.0;/MACOSX_DEPLOYMENT_TARGET = 26.0;/g' voxline.xcodeproj/project.pbxproj
grep -c "MACOSX_DEPLOYMENT_TARGET = 26.0;" voxline.xcodeproj/project.pbxproj
```
Expected: `4`.

- [ ] **Step 4: Move CI and release to macOS 26 runners**

In `.github/workflows/ci.yml` and `.github/workflows/release.yml`, change `runs-on: macos-15` to `runs-on: macos-26`. In both files, change the Xcode selection step name to `Select latest Xcode 26` and the glob `/Applications/Xcode_16*.app` to `/Applications/Xcode_26*.app` and the error text `No Xcode 16.x found on runner` to `No Xcode 26.x found on runner`.

```bash
sed -i '' -e 's/runs-on: macos-15/runs-on: macos-26/' -e 's/Xcode_16\*/Xcode_26*/g' -e 's/Xcode 16/Xcode 26/g' .github/workflows/ci.yml .github/workflows/release.yml
grep -n "macos-26\|Xcode_26\|Xcode 26" .github/workflows/ci.yml .github/workflows/release.yml
```
Expected: one `macos-26`, one `Xcode_26*`, and two `Xcode 26` hits per file. If a later CI run reports no runner matching `macos-26`, use `macos-latest` instead.

- [ ] **Step 5: Update the platform floor in the docs**

`README.md`:
- line 11: `macOS 14.0+ · Apple Silicon · Bring your own API key` → `macOS 26+ · Apple Silicon · Bring your own API key`
- line 15: `macOS-14%2B` → `macOS-26%2B`
- requirements row: `| **macOS** | 14 (Sonoma) or later |` → `| **macOS** | 26 (Tahoe) or later |`
- disk row: `Models cache inside the app container.` → ``Models cache in `~/Library/Application Support/voxline`.``

`AGENTS.md`, Build & test section: `Requires Xcode 16.x and macOS (Apple Silicon)` → `Requires Xcode 26 and macOS 26 (Apple Silicon)`; `` on `macos-15` runners `` → `` on `macos-26` runners ``.

- [ ] **Step 6: Build and run the full suite**

```bash
xcodebuild build -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' 2>&1 | grep -E "Test Suite|passed|failed" | tail -5
```
Expected: `** BUILD SUCCEEDED **`, all tests pass.

- [ ] **Step 7: Confirm the signed app carries no sandbox entitlement**

```bash
./scripts/build-local.sh --debug --no-install
codesign -d --entitlements :- .build-local/Build/Products/Debug/voxline.app 2>/dev/null | grep -c "app-sandbox"
```
Expected: `0`.

- [ ] **Step 8: Commit**

```bash
git add voxline/voxline.entitlements voxline/Info.plist voxline.xcodeproj/project.pbxproj .github/workflows/ci.yml .github/workflows/release.yml README.md AGENTS.md
git commit -s -m "build: drop the App Sandbox and raise the floor to macOS 26

Removes the sandbox entitlement, its mach-lookup exceptions, the
network-client entitlement, and Sparkle's sandbox-only launcher flag.
Hardened runtime, audio input, and the keychain access group stay.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: Move `AppCoordinator` into its own file

**Files:**
- Create: `voxline/AppCoordinator.swift`
- Modify: `voxline/voxlineApp.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `voxline/AppCoordinator.swift` containing `@MainActor final class AppCoordinator` and its `apply(_:)` extension, byte-identical to before. Later tasks edit this file, not `voxlineApp.swift`.

- [ ] **Step 1: Cut the class out of voxlineApp.swift**

```bash
START=$(( $(grep -n '^final class AppCoordinator {' voxline/voxlineApp.swift | cut -d: -f1) - 1 ))
sed -n "${START},\$p" voxline/voxlineApp.swift > /tmp/coordinator-body.swift
head -1 /tmp/coordinator-body.swift
```
Expected: `@MainActor`.

- [ ] **Step 2: Write the new file with imports**

```bash
{ printf 'import AppKit\nimport Observation\nimport SwiftUI\n\n'; cat /tmp/coordinator-body.swift; } > voxline/AppCoordinator.swift
sed -i '' "${START},\$d" voxline/voxlineApp.swift
tail -3 voxline/voxlineApp.swift
```
Expected: the file now ends with `AppDelegate`'s closing brace. Remove any trailing blank lines so the file ends with a single `}`.

- [ ] **Step 3: Build and run the full suite**

```bash
xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' 2>&1 | grep -E "BUILD|passed|failed" | tail -3
```
Expected: build succeeds, all tests pass.

- [ ] **Step 4: Commit**

```bash
git add voxline/AppCoordinator.swift voxline/voxlineApp.swift
git commit -s -m "refactor(app): move AppCoordinator into its own file

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: `AppPaths` owns every path; WhisperKit downloads under Application Support

**Files:**
- Modify: `voxline/Storage/AppPaths.swift`
- Modify: `voxline/Transcription/TranscriptionService.swift`
- Create: `voxlineTests/AppPathsTests.swift`

**Interfaces:**
- Produces:
  - `AppPaths.bundleID: String` (`"com.voxline.app"`)
  - `AppPaths.modelCacheDirectory() throws -> URL` — `~/Library/Application Support/voxline/huggingface`, created on demand. WhisperKit's `downloadBase`.
  - `AppPaths.legacyContainerDataDirectory(home: URL = .homeDirectory) -> URL` — `<home>/Library/Containers/com.voxline.app/Data`.
- Task 4 consumes both new functions.

- [ ] **Step 1: Write the failing tests**

Create `voxlineTests/AppPathsTests.swift`:

```swift
import Testing
import Foundation
@testable import voxline

@Suite struct AppPathsTests {

    @Test func modelCacheDirectory_isUnderApplicationSupport_andExists() throws {
        let url = try AppPaths.modelCacheDirectory()
        #expect(Array(url.pathComponents.suffix(3)) == ["Application Support", "voxline", "huggingface"])
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }

    @Test func modesFile_isNextToTheModelCache() throws {
        let modes = try AppPaths.modesFile()
        let cache = try AppPaths.modelCacheDirectory()
        #expect(modes.deletingLastPathComponent() == cache.deletingLastPathComponent())
        #expect(modes.lastPathComponent == "modes.json")
    }

    @Test func legacyContainerDataDirectory_pointsInsideTheOldSandbox() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let url = AppPaths.legacyContainerDataDirectory(home: home)
        #expect(url.path == "/Users/example/Library/Containers/com.voxline.app/Data")
    }
}
```

- [ ] **Step 2: Run to verify they fail**

```bash
xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/AppPathsTests 2>&1 | grep -E "error:|passed|failed" | head
```
Expected: compile error, `type 'AppPaths' has no member 'modelCacheDirectory'`.

- [ ] **Step 3: Implement AppPaths**

Replace `voxline/Storage/AppPaths.swift` with:

```swift
import Foundation

/// Every on-disk location the app owns. Nothing else builds paths.
enum AppPaths {

    static let bundleID = "com.voxline.app"

    static func applicationSupportDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = base.appending(path: "voxline", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func modesFile() throws -> URL {
        try applicationSupportDirectory().appending(path: "modes.json")
    }

    /// Root WhisperKit downloads into. The Hub layout underneath is
    /// `models/argmaxinc/whisperkit-coreml/<variant>`.
    static func modelCacheDirectory() throws -> URL {
        let dir = try applicationSupportDirectory().appending(path: "huggingface", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Where sandboxed 0.3.x builds kept everything. Read only by `ContainerMigration`.
    static func legacyContainerDataDirectory(home: URL = .homeDirectory) -> URL {
        home.appending(path: "Library/Containers/\(bundleID)/Data", directoryHint: .isDirectory)
    }
}
```

- [ ] **Step 4: Point TranscriptionService at the new cache root**

In `voxline/Transcription/TranscriptionService.swift`:

Replace `preflightDiskSpace(for:)`'s body with:

```swift
        let requiredMB = model.approxSizeMB + diskSpaceHeadroomMB
        let requiredBytes = Int64(requiredMB) * 1_048_576
        guard let cacheRoot = try? AppPaths.modelCacheDirectory() else { return }
        let values = try? cacheRoot.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values?.volumeAvailableCapacityForImportantUsage else {
            return
        }
        if available < requiredBytes {
            throw TranscriptionPrepError.insufficientDiskSpace(
                model: model,
                requiredMB: requiredMB,
                availableMB: Int(available / 1_048_576)
            )
        }
```

Replace `prepareModel(progressHandler:)` with:

```swift
    func prepareModel(progressHandler: @escaping @Sendable (Double) -> Void) async throws {
        if Self.isModelCached(model) { return }
        try Self.preflightDiskSpace(for: model)
        let downloadBase = try AppPaths.modelCacheDirectory()
        _ = try await WhisperKit.download(
            variant: model.whisperKitIdentifier,
            downloadBase: downloadBase,
            from: "argmaxinc/whisperkit-coreml"
        ) { progress in
            progressHandler(progress.fractionCompleted)
        }
    }
```

Replace `cachedModelFolder(for:)` with:

```swift
    private static func cachedModelFolder(for model: WhisperModel) -> URL? {
        guard let base = try? AppPaths.modelCacheDirectory() else { return nil }
        let path = base
            .appending(path: "models", directoryHint: .isDirectory)
            .appending(path: "argmaxinc", directoryHint: .isDirectory)
            .appending(path: "whisperkit-coreml", directoryHint: .isDirectory)
            .appending(path: model.whisperKitIdentifier, directoryHint: .isDirectory)
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: path.path)) ?? []
        return contents.isEmpty ? nil : path
    }
```

In `loadIfNeeded()`, directly above `let task = Task<WhisperKit, Error> {`, add:

```swift
            let downloadBase = try AppPaths.modelCacheDirectory()
```

and change the `WhisperKitConfig(` call inside the task to pass the base as its second argument:

```swift
                let config = WhisperKitConfig(
                    model: variant,
                    downloadBase: downloadBase,
                    modelRepo: "argmaxinc/whisperkit-coreml",
                    verbose: false,
                    logLevel: .error,
                    prewarm: true,
                    load: true,
                    download: true
                )
```

Also delete the now-stale sentence `The path is sandbox-aware via FileManager.documentDirectory.` from the doc comment above `cachedModelFolder`.

- [ ] **Step 5: Run the tests**

```bash
xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/AppPathsTests -only-testing:voxlineTests/WhisperModelTests 2>&1 | grep -E "error:|passed|failed" | tail -3
```
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add voxline/Storage/AppPaths.swift voxline/Transcription/TranscriptionService.swift voxlineTests/AppPathsTests.swift
git commit -s -m "feat(storage): root the model cache under Application Support

Unsandboxed, Documents resolves to the user's real ~/Documents, so
WhisperKit's default download base is no longer acceptable. AppPaths now
owns the cache root and the legacy container path.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: One-time migration out of the sandbox container

**Files:**
- Create: `voxline/Storage/ContainerMigration.swift`
- Create: `voxlineTests/ContainerMigrationTests.swift`
- Modify: `voxline/voxlineApp.swift` (`AppDelegate`)
- Modify: `voxline/AppCoordinator.swift` (`startIfNeeded`)

**Interfaces:**
- Consumes: `AppPaths.legacyContainerDataDirectory()`, `AppPaths.applicationSupportDirectory()`, `AppPaths.bundleID`.
- Produces:
  - `struct ContainerMigration` with `init(legacyDataDirectory:applicationSupportDirectory:cachesDirectory:defaults:fileManager:)`, `static func standard() -> ContainerMigration?`, `func runIfNeeded() -> Report?`, `static let completedKey = "voxline.migration.containerMigrated"`.
  - `ContainerMigration.Report: Equatable` with `preferencesCopied: Int`, `movedModes`, `movedModelCache`, `movedANECache: Bool`, `failures: [String]`.
  - `AppCoordinator.startIfNeeded(state:historyStore:migration:)` gains a `migration: ContainerMigration.Report? = nil` parameter.

- [ ] **Step 1: Write the failing tests**

Create `voxlineTests/ContainerMigrationTests.swift`:

```swift
import Testing
import Foundation
@testable import voxline

@Suite struct ContainerMigrationTests {

    private struct Fixture {
        let root: URL
        let legacy: URL
        let appSupport: URL
        let caches: URL
        let defaults: UserDefaults
        let suiteName: String

        func tearDown() {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "voxline-migration-\(UUID().uuidString)", directoryHint: .isDirectory)
        let legacy = root.appending(path: "Containers/com.voxline.app/Data", directoryHint: .isDirectory)
        let appSupport = root.appending(path: "Application Support/voxline", directoryHint: .isDirectory)
        let caches = root.appending(path: "Caches", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        let suiteName = "voxline-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return Fixture(root: root, legacy: legacy, appSupport: appSupport, caches: caches, defaults: defaults, suiteName: suiteName)
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func legacyPrefsPlist(_ f: Fixture) -> URL {
        f.legacy.appending(path: "Library/Preferences/com.voxline.app.plist")
    }

    private func populateLegacy(_ f: Fixture) throws {
        let prefs: [String: Any] = ["voxline.whisper.model": "smallEn", "voxline.firstRun.completed": true]
        let plist = legacyPrefsPlist(f)
        try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        #expect((prefs as NSDictionary).write(to: plist, atomically: true))
        try write("[]", to: f.legacy.appending(path: "Library/Application Support/voxline/modes.json"))
        try write("weights", to: f.legacy.appending(path: "Documents/huggingface/models/argmaxinc/whisperkit-coreml/openai_whisper-small.en/model.bin"))
        try write("ane", to: f.legacy.appending(path: "Library/Caches/com.voxline.app/com.apple.e5rt.e5bundlecache/blob"))
    }

    private func migration(_ f: Fixture) -> ContainerMigration {
        ContainerMigration(
            legacyDataDirectory: f.legacy,
            applicationSupportDirectory: f.appSupport,
            cachesDirectory: f.caches,
            defaults: f.defaults
        )
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    @Test func moves_files_and_copies_preferences_exactly_once() throws {
        let f = try makeFixture()
        defer { f.tearDown() }
        try populateLegacy(f)

        let report = try #require(migration(f).runIfNeeded())

        #expect(report.movedModes)
        #expect(report.movedModelCache)
        #expect(report.movedANECache)
        #expect(report.preferencesCopied == 2)
        #expect(report.failures.isEmpty)
        #expect(exists(f.appSupport.appending(path: "modes.json")))
        #expect(exists(f.appSupport.appending(path: "huggingface/models/argmaxinc/whisperkit-coreml/openai_whisper-small.en/model.bin")))
        #expect(exists(f.caches.appending(path: "com.voxline.app/com.apple.e5rt.e5bundlecache/blob")))
        #expect(!exists(f.legacy.appending(path: "Documents/huggingface")))
        #expect(f.defaults.string(forKey: "voxline.whisper.model") == "smallEn")
        #expect(f.defaults.bool(forKey: "voxline.firstRun.completed"))
        #expect(f.defaults.bool(forKey: ContainerMigration.completedKey))
        #expect(migration(f).runIfNeeded() == nil)
    }

    @Test func missing_container_marks_complete_and_returns_nil() throws {
        let f = try makeFixture()
        defer { f.tearDown() }

        #expect(migration(f).runIfNeeded() == nil)
        #expect(f.defaults.bool(forKey: ContainerMigration.completedKey))
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.appSupport.path).isEmpty)
    }

    @Test func never_overwrites_existing_destinations_or_defaults() throws {
        let f = try makeFixture()
        defer { f.tearDown() }
        try populateLegacy(f)
        try write("existing", to: f.appSupport.appending(path: "modes.json"))
        f.defaults.set("largeV3Turbo", forKey: "voxline.whisper.model")

        let report = try #require(migration(f).runIfNeeded())

        #expect(!report.movedModes)
        #expect(try String(contentsOf: f.appSupport.appending(path: "modes.json"), encoding: .utf8) == "existing")
        #expect(exists(f.legacy.appending(path: "Library/Application Support/voxline/modes.json")))
        #expect(f.defaults.string(forKey: "voxline.whisper.model") == "largeV3Turbo")
        #expect(report.preferencesCopied == 1)
        #expect(report.movedModelCache)
    }

    @Test func unreadable_preferences_are_reported_but_do_not_stop_the_move() throws {
        let f = try makeFixture()
        defer { f.tearDown() }
        try populateLegacy(f)
        try "not a plist".write(to: legacyPrefsPlist(f), atomically: true, encoding: .utf8)

        let report = try #require(migration(f).runIfNeeded())

        #expect(report.failures.count == 1)
        #expect(report.preferencesCopied == 0)
        #expect(report.movedModelCache)
        #expect(f.defaults.bool(forKey: ContainerMigration.completedKey))
    }
}
```

- [ ] **Step 2: Run to verify they fail**

```bash
xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/ContainerMigrationTests 2>&1 | grep -E "error:|passed|failed" | head -3
```
Expected: compile error, `cannot find 'ContainerMigration' in scope`.

- [ ] **Step 3: Implement ContainerMigration**

Create `voxline/Storage/ContainerMigration.swift`:

```swift
import Foundation

/// One-shot move of app data out of the 0.3.x sandbox container. Runs before
/// anything reads `UserDefaults`, the modes file, or the model cache. Never
/// overwrites a destination that already exists, and marks itself complete
/// even when a step fails so a broken container can't block every launch.
struct ContainerMigration {

    static let completedKey = "voxline.migration.containerMigrated"

    struct Report: Equatable {
        var preferencesCopied = 0
        var movedModes = false
        var movedModelCache = false
        var movedANECache = false
        var failures: [String] = []
    }

    let legacyDataDirectory: URL
    let applicationSupportDirectory: URL
    let cachesDirectory: URL
    let defaults: UserDefaults
    let fileManager: FileManager

    init(
        legacyDataDirectory: URL = AppPaths.legacyContainerDataDirectory(),
        applicationSupportDirectory: URL,
        cachesDirectory: URL,
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) {
        self.legacyDataDirectory = legacyDataDirectory
        self.applicationSupportDirectory = applicationSupportDirectory
        self.cachesDirectory = cachesDirectory
        self.defaults = defaults
        self.fileManager = fileManager
    }

    /// Production instance. Nil only when Application Support itself is unavailable.
    static func standard() -> ContainerMigration? {
        guard let appSupport = try? AppPaths.applicationSupportDirectory(),
              let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        return ContainerMigration(applicationSupportDirectory: appSupport, cachesDirectory: caches)
    }

    /// Nil when there was nothing to do: already migrated, or no container on disk.
    @discardableResult
    func runIfNeeded() -> Report? {
        guard !defaults.bool(forKey: Self.completedKey) else { return nil }
        guard fileManager.fileExists(atPath: legacyDataDirectory.path) else {
            defaults.set(true, forKey: Self.completedKey)
            return nil
        }

        var report = Report()
        copyPreferences(into: &report)
        move(
            legacyDataDirectory.appending(path: "Library/Application Support/voxline/modes.json"),
            to: applicationSupportDirectory.appending(path: "modes.json"),
            flag: \.movedModes, report: &report
        )
        move(
            legacyDataDirectory.appending(path: "Documents/huggingface", directoryHint: .isDirectory),
            to: applicationSupportDirectory.appending(path: "huggingface", directoryHint: .isDirectory),
            flag: \.movedModelCache, report: &report
        )
        move(
            legacyDataDirectory.appending(path: "Library/Caches/\(AppPaths.bundleID)/com.apple.e5rt.e5bundlecache", directoryHint: .isDirectory),
            to: cachesDirectory.appending(path: "\(AppPaths.bundleID)/com.apple.e5rt.e5bundlecache", directoryHint: .isDirectory),
            flag: \.movedANECache, report: &report
        )
        defaults.set(true, forKey: Self.completedKey)
        return report
    }

    private func copyPreferences(into report: inout Report) {
        let plist = legacyDataDirectory.appending(path: "Library/Preferences/\(AppPaths.bundleID).plist")
        guard fileManager.fileExists(atPath: plist.path) else { return }
        guard let dict = NSDictionary(contentsOf: plist) as? [String: Any] else {
            report.failures.append("preferences: unreadable plist")
            return
        }
        for (key, value) in dict where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
            report.preferencesCopied += 1
        }
    }

    private func move(_ source: URL, to destination: URL, flag: WritableKeyPath<Report, Bool>, report: inout Report) {
        guard fileManager.fileExists(atPath: source.path) else { return }
        guard !fileManager.fileExists(atPath: destination.path) else { return }
        do {
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.moveItem(at: source, to: destination)
            report[keyPath: flag] = true
        } catch {
            report.failures.append("\(source.lastPathComponent): \(error.localizedDescription)")
        }
    }
}
```

- [ ] **Step 4: Run the tests**

```bash
xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/ContainerMigrationTests 2>&1 | grep -E "error:|passed|failed" | tail -3
```
Expected: 4 tests pass.

- [ ] **Step 5: Run it before anything reads defaults**

In `voxline/voxlineApp.swift`, `AppDelegate`: `historyStore` reads `UserDefaults` in its initializer, so it must become lazy, and the migration must be the first statement of launch.

Change:
```swift
    let historyStore = DictationHistoryStore()
```
to:
```swift
    lazy var historyStore = DictationHistoryStore()
```

Change `applicationDidFinishLaunching` to:
```swift
    func applicationDidFinishLaunching(_ notification: Notification) {
        let migration = ContainerMigration.standard()?.runIfNeeded()
        windowVisibility.start()
        coordinator.startIfNeeded(state: appState, historyStore: historyStore, migration: migration)
        _ = updateService
        observeStatusForUpdates()
    }
```

In `voxline/AppCoordinator.swift`, change `startIfNeeded` to:

```swift
    func startIfNeeded(state: AppState, historyStore: DictationHistoryStore, migration: ContainerMigration.Report? = nil) {
        guard !didStart else { return }
        didStart = true
        self.appState = state

        if let migration {
            AppLog.pipeline.info("container migration: prefs=\(migration.preferencesCopied) modes=\(migration.movedModes) models=\(migration.movedModelCache) ane=\(migration.movedANECache)")
            for failure in migration.failures {
                AppLog.pipeline.error("container migration failed: \(failure, privacy: .public)")
            }
        }

        let settings = AppSettings()
        logLaunchTrace(settings: settings)
        if !settings.hasCompletedFirstRun {
            startWizardThenApp(state: state, settings: settings, historyStore: historyStore)
        } else {
            startApp(state: state, settings: settings, historyStore: historyStore)
        }

        if let migration, !migration.failures.isEmpty {
            flashToast("Some data couldn't be moved from the previous version. See the log.", state: state)
        }
    }

    private func flashToast(_ message: String, state: AppState) {
        state.toastMessage = message
        Task { @MainActor [weak state] in
            try? await Task.sleep(for: .seconds(4))
            if state?.toastMessage == message { state?.toastMessage = nil }
        }
    }
```

- [ ] **Step 6: Build and run the full suite**

```bash
xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' 2>&1 | grep -E "BUILD|passed|failed" | tail -3
```
Expected: build succeeds, all tests pass.

- [ ] **Step 7: Commit**

```bash
git add voxline/Storage/ContainerMigration.swift voxlineTests/ContainerMigrationTests.swift voxline/voxlineApp.swift voxline/AppCoordinator.swift
git commit -s -m "feat(storage): migrate 0.3.x container data on first unsandboxed launch

Copies preferences into the standard domain and moves modes.json, the
Whisper cache, and the ANE bundle cache out of the container. Same-volume
renames, never overwrites, one shot.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: AX messaging timeout; delete the paste-eligibility shims

**Files:**
- Create: `voxline/Util/AXMessagingTimeout.swift`
- Modify: `voxline/Output/ClipboardInjector.swift`
- Modify: `voxline/Util/AXAttributeReading.swift` (doc comment)
- Modify: `voxline/AppCoordinator.swift` (`startIfNeeded`, `buildServices`)

**Interfaces:**
- Produces: `AXMessagingTimeout.install()` and `AXMessagingTimeout.seconds: Float = 0.5`.
- Removes: `PasteEligibilityChecking`, `AlwaysPasteEligible`, `DefaultPasteEligibility`, `AXMenuBarInspector`, `ClipboardInjector.pasteEligibility`, the `pasteEligibility:` init parameter, and `TextInsertionError.clipboardPasteNotApplicable`. No test references any of them.

- [ ] **Step 1: Add the timeout installer**

Create `voxline/Util/AXMessagingTimeout.swift`:

```swift
import ApplicationServices

/// Caps how long any Accessibility request may block on a busy target app.
/// The system default is about six seconds per call, long enough to beachball
/// voxline on the main actor while an Electron app is busy.
enum AXMessagingTimeout {

    static let seconds: Float = 0.5

    /// Setting the timeout on the system-wide element makes it the default for
    /// every element this process creates that does not set its own.
    static func install() {
        _ = AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), seconds)
    }
}
```

- [ ] **Step 2: Install it at launch**

In `voxline/AppCoordinator.swift`, `startIfNeeded`, insert as the first statement inside the function body, above `guard !didStart else { return }`:

```swift
        AXMessagingTimeout.install()
```

- [ ] **Step 3: Delete the eligibility types from the injector**

In `voxline/Output/ClipboardInjector.swift` delete, in full:
- the `PasteEligibilityChecking` protocol and its doc comment,
- the `AlwaysPasteEligible` struct and its doc comment,
- the `DefaultPasteEligibility` struct and its doc comment,
- the `AXMenuBarInspector` enum and its doc comment (everything from `/// Standalone AX menu-bar inspection` through the enum's closing brace),
- the `case clipboardPasteNotApplicable(String)` line in `TextInsertionError` and its `case .clipboardPasteNotApplicable(let reason): return "Clipboard paste skipped: \(reason)."` arm,
- the `let pasteEligibility: PasteEligibilityChecking` property,
- the `pasteEligibility: PasteEligibilityChecking = AlwaysPasteEligible(),` init parameter and the `self.pasteEligibility = pasteEligibility` assignment,
- in `injectViaClipboardPaste`, the `// 0. Pre-flight eligibility.` comment block and the `guard pasteEligibility.isPasteEligible() else { ... }` statement.

Verify nothing is left:
```bash
grep -n "Eligib\|AXMenuBarInspector\|clipboardPasteNotApplicable" voxline/Output/ClipboardInjector.swift
```
Expected: no output.

- [ ] **Step 4: Remove the shim from the coordinator's wiring**

In `voxline/AppCoordinator.swift`, `buildServices`, delete the comment block that begins `// Paste eligibility must fail OPEN under the App Sandbox.` (through `...a non-sandboxed build would have used.`) and change the injector construction to:

```swift
        let injector = ClipboardInjector(
            focusedTextSystem: focusedTextSystem,
            chordIsHeld: ClipboardInjector.makeChordIsHeld(chord: chordProvider, command: commandModifierProvider)
        )
```

- [ ] **Step 5: Fix the doc comment in AXAttributeReading.swift**

Change the comment above `extension AXUIElement` to:

```swift
/// Tiny read-only AX helpers used by the focused-element inspectors and the
/// context probe. Each call is one synchronous cross-process IPC, bounded by
/// `AXMessagingTimeout`; callers that need a tighter deadline guard wrap
/// these themselves.
```

- [ ] **Step 6: Build and run the injector and pipeline suites**

```bash
xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/ClipboardInjectorTests -only-testing:voxlineTests/ClipboardInjectorReplaceTests -only-testing:voxlineTests/CapturePipelineTests 2>&1 | grep -E "error:|passed|failed" | tail -3
```
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add voxline/Util/AXMessagingTimeout.swift voxline/Output/ClipboardInjector.swift voxline/Util/AXAttributeReading.swift voxline/AppCoordinator.swift
git commit -s -m "refactor(output): delete sandbox paste-eligibility shims; cap AX request time

The menu-bar walk and the always-eligible stand-in only existed because
the sandbox blocked focused-element reads. A process-wide 0.5s AX
messaging timeout replaces the ~6s system default.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: AX-first selection reader with Cmd+C fallback

**Files:**
- Create: `voxline/Context/AXSelectionReader.swift`
- Create: `voxlineTests/AXSelectionReaderTests.swift`
- Modify: `voxline/Context/SelectionSnapshot.swift` (doc comment)
- Modify: `voxline/AppCoordinator.swift` (`buildServices`)

**Interfaces:**
- Consumes: `SelectionSnapshotting` (`func readSelection() async -> String?`), `DefaultSelectionSnapshot`, `AXUIElement.systemWideFocusedElement()`, `AXUIElement.stringAttribute(_:)`.
- Produces: `struct AXSelectionReader: SelectionSnapshotting` with `init(readAX: @escaping @Sendable () -> String? = AXSelectionReader.focusedSelectedText, fallback: any SelectionSnapshotting = DefaultSelectionSnapshot())`.

- [ ] **Step 1: Write the failing tests**

Create `voxlineTests/AXSelectionReaderTests.swift`:

```swift
import Testing
@testable import voxline

@Suite struct AXSelectionReaderTests {

    final class RecordingFallback: SelectionSnapshotting, @unchecked Sendable {
        var result: String?
        private(set) var calls = 0
        init(result: String?) { self.result = result }
        func readSelection() async -> String? { calls += 1; return result }
    }

    @Test func uses_ax_selection_when_present_and_skips_fallback() async {
        let fallback = RecordingFallback(result: "from clipboard")
        let reader = AXSelectionReader(readAX: { "from ax" }, fallback: fallback)
        #expect(await reader.readSelection() == "from ax")
        #expect(fallback.calls == 0)
    }

    @Test func falls_back_when_ax_returns_nil() async {
        let fallback = RecordingFallback(result: "from clipboard")
        let reader = AXSelectionReader(readAX: { nil }, fallback: fallback)
        #expect(await reader.readSelection() == "from clipboard")
        #expect(fallback.calls == 1)
    }

    @Test func falls_back_when_ax_returns_empty() async {
        let fallback = RecordingFallback(result: nil)
        let reader = AXSelectionReader(readAX: { "" }, fallback: fallback)
        #expect(await reader.readSelection() == nil)
        #expect(fallback.calls == 1)
    }
}
```

- [ ] **Step 2: Run to verify they fail**

```bash
xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/AXSelectionReaderTests 2>&1 | grep -E "error:|passed|failed" | head -3
```
Expected: compile error, `cannot find 'AXSelectionReader' in scope`.

- [ ] **Step 3: Implement the reader**

Create `voxline/Context/AXSelectionReader.swift`:

```swift
import ApplicationServices
import Foundation

/// Reads the focused element's selection through Accessibility and falls back
/// to the synthetic-Cmd+C reader only when AX exposes nothing. Secure fields
/// never yield a selection.
struct AXSelectionReader: SelectionSnapshotting {

    let readAX: @Sendable () -> String?
    let fallback: any SelectionSnapshotting

    init(
        readAX: @escaping @Sendable () -> String? = AXSelectionReader.focusedSelectedText,
        fallback: any SelectionSnapshotting = DefaultSelectionSnapshot()
    ) {
        self.readAX = readAX
        self.fallback = fallback
    }

    func readSelection() async -> String? {
        if let selected = readAX(), !selected.isEmpty { return selected }
        return await fallback.readSelection()
    }

    static let focusedSelectedText: @Sendable () -> String? = {
        guard AXIsProcessTrusted(),
              let element = AXUIElement.systemWideFocusedElement() else { return nil }
        if element.stringAttribute(kAXSubroleAttribute) == (kAXSecureTextFieldSubrole as String) { return nil }
        return element.stringAttribute(kAXSelectedTextAttribute)
    }
}
```

- [ ] **Step 4: Demote the Cmd+C reader to a fallback in its doc comment**

In `voxline/Context/SelectionSnapshot.swift`, replace the comment block above `protocol SelectionSnapshotting` (the paragraph starting `/// Reads the current selection from the frontmost app` through `/// never copied out.`) with:

```swift
/// Reads the current selection by synthesizing a Cmd+C and reading the copied
/// string back off the pasteboard. This is the fallback behind
/// `AXSelectionReader` for apps whose AX tree exposes no selected text (some
/// Electron and web views). The user's clipboard is snapshotted and always
/// restored, and Cmd+C in a secure (password) field is a no-op on macOS, so a
/// selected password is never copied out.
```

- [ ] **Step 5: Wire it in**

In `voxline/AppCoordinator.swift`, `buildServices`, change the `CapturePipeline(` construction to pass the reader explicitly, adding one argument after `contextCapture: contextCapture`:

```swift
            contextCapture: contextCapture,
            selectionSnapshot: AXSelectionReader()
```

- [ ] **Step 6: Run the tests**

```bash
xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/AXSelectionReaderTests 2>&1 | grep -E "error:|passed|failed" | tail -3
```
Expected: 3 tests pass.

- [ ] **Step 7: Commit**

```bash
git add voxline/Context/AXSelectionReader.swift voxlineTests/AXSelectionReaderTests.swift voxline/Context/SelectionSnapshot.swift voxline/AppCoordinator.swift
git commit -s -m "feat(context): read the selection through AX; Cmd+C becomes the fallback

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: Dictating with no editable field focused copies instead of pasting

**Files:**
- Modify: `voxline/Modes/FocusedField.swift`
- Modify: `voxline/Pipeline/CapturePipeline.swift` (`finalizeRecording`)
- Test: `voxlineTests/FocusedFieldTests.swift`, `voxlineTests/CapturePipelineTests.swift`

**Interfaces:**
- Produces: `FocusedField.isEditable: Bool` and `FocusedField.nonEditableRoles: Set<String>`.
- Pipeline behavior: after cleanup and history, if the field inspected at finalize time is not editable, the cleaned text goes through `transcriptFallback` (clipboard), the pill shows `No text field focused — copied`, and nothing is injected.

- [ ] **Step 1: Write the failing FocusedField tests**

Append inside the `@Suite` in `voxlineTests/FocusedFieldTests.swift`:

```swift
    @Test func button_is_not_editable() {
        #expect(FocusedField(role: "AXButton", subrole: nil).isEditable == false)
    }

    @Test func static_text_is_not_editable() {
        #expect(FocusedField(role: "AXStaticText", subrole: nil).isEditable == false)
    }

    @Test func text_area_and_text_field_are_editable() {
        #expect(FocusedField(role: "AXTextArea", subrole: nil).isEditable)
        #expect(FocusedField(role: "AXTextField", subrole: nil).isEditable)
    }

    @Test func unknown_and_nil_roles_are_treated_as_editable() {
        #expect(FocusedField(role: "AXGroup", subrole: nil).isEditable)
        #expect(FocusedField(role: "AXWebArea", subrole: nil).isEditable)
        #expect(FocusedField(role: nil, subrole: nil).isEditable)
    }
```

- [ ] **Step 2: Write the failing pipeline test**

Append inside the `@Suite` in `voxlineTests/CapturePipelineTests.swift`, next to `paste_failure_stillRecordsInHistory`:

```swift
    @Test func finalize_nonEditableFocusedField_copiesInsteadOfPasting() async throws {
        let (pipe, state, _, _, _, _, _, injector, history) = makePipeline(
            focusedField: FocusedField(role: "AXButton", subrole: nil)
        )
        let copied = LockedBox<[String]>([])
        pipe.transcriptFallback = { text in copied.mutate { $0.append(text) } }

        await startAndFinalize(pipe, state: state)

        #expect(injector.injected.isEmpty)
        #expect(copied.read() == ["cleaned"])
        #expect(state.toastMessage == "No text field focused — copied")
        #expect(state.status == .idle)
        #expect(history.items.first?.cleanedText == "cleaned")
    }
```

(`LockedBox` is defined at file scope in `voxlineTests/ClipboardInjectorTests.swift` and is visible to every test file in the module.)

- [ ] **Step 3: Run to verify they fail**

```bash
xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/FocusedFieldTests -only-testing:voxlineTests/CapturePipelineTests 2>&1 | grep -E "error:|passed|failed" | head -3
```
Expected: compile error, `value of type 'FocusedField' has no member 'isEditable'`.

- [ ] **Step 4: Implement `isEditable`**

Append to `voxline/Modes/FocusedField.swift`:

```swift
extension FocusedField {

    /// Roles that can never take typed text. Everything else, including nil
    /// and unfamiliar roles, counts as editable so an AX-opaque editor is
    /// never refused.
    static let nonEditableRoles: Set<String> = [
        "AXApplication", "AXButton", "AXCell", "AXCheckBox", "AXDisclosureTriangle",
        "AXImage", "AXIncrementor", "AXLink", "AXList", "AXMenu", "AXMenuBar",
        "AXMenuButton", "AXMenuItem", "AXOutline", "AXPopUpButton",
        "AXProgressIndicator", "AXRadioButton", "AXRow", "AXScrollArea",
        "AXSlider", "AXSplitGroup", "AXStaticText", "AXTabGroup", "AXTable",
        "AXToolbar", "AXWindow",
    ]

    var isEditable: Bool {
        guard let role else { return true }
        return !Self.nonEditableRoles.contains(role)
    }
}
```

- [ ] **Step 5: Branch in the pipeline**

In `voxline/Pipeline/CapturePipeline.swift`, `finalizeRecording`, directly above `// 4. Paste.`, insert:

```swift
        guard field?.isEditable ?? true else {
            transcriptFallback(cleaned)
            resetIdle()
            showToast("No text field focused — copied")
            return
        }
```

- [ ] **Step 6: Run the tests**

```bash
xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/FocusedFieldTests -only-testing:voxlineTests/CapturePipelineTests 2>&1 | grep -E "error:|passed|failed" | tail -3
```
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add voxline/Modes/FocusedField.swift voxline/Pipeline/CapturePipeline.swift voxlineTests/FocusedFieldTests.swift voxlineTests/CapturePipelineTests.swift
git commit -s -m "fix(pipeline): copy instead of pasting when no editable field is focused

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 8: History keeps the raw transcript

**Files:**
- Modify: `voxline/Storage/DictationHistoryStore.swift`
- Modify: `voxline/UI/HistoryView.swift`
- Modify: `voxline/Pipeline/CapturePipeline.swift` (two `historyStore.record` calls)
- Test: `voxlineTests/DictationHistoryStoreTests.swift`, `voxlineTests/CapturePipelineTests.swift`

**Interfaces:**
- Produces: `DictationHistoryItem.rawTranscript: String?` (nil for rows written before 0.4.0) and `DictationHistoryStore.record(cleanedText:rawTranscript:mode:context:)` where `rawTranscript: String? = nil`. `updateMostRecent` preserves it.
- Pipeline passes the Whisper transcript for dictations and the spoken command for transforms.

- [ ] **Step 1: Write the failing store tests**

Append inside the `@Suite` in `voxlineTests/DictationHistoryStoreTests.swift`:

```swift
    @Test func record_stores_raw_transcript() throws {
        let store = DictationHistoryStore(defaults: makeDefaults())
        store.record(cleanedText: "Hello, world.", rawTranscript: "um hello world", mode: anyMode(), context: .empty)
        let item = try #require(store.items.first)
        #expect(item.rawTranscript == "um hello world")
    }

    @Test func updateMostRecent_preserves_raw_transcript() throws {
        let store = DictationHistoryStore(defaults: makeDefaults())
        store.record(cleanedText: "first", rawTranscript: "raw", mode: anyMode(), context: .empty)
        store.updateMostRecent(cleanedText: "second")
        let item = try #require(store.items.first)
        #expect(item.cleanedText == "second")
        #expect(item.rawTranscript == "raw")
    }
```

And in the existing `loads_old_schema_json_with_nil_new_fields` test, add after `#expect(first.appBundleID == nil)`:

```swift
        #expect(first.rawTranscript == nil)
```

- [ ] **Step 2: Write the failing pipeline test**

Append inside the `@Suite` in `voxlineTests/CapturePipelineTests.swift`:

```swift
    @Test func finalizeRecording_recordsRawTranscriptInHistory() async throws {
        let (pipe, state, _, _, _, _, _, _, history) = makePipeline()
        await startAndFinalize(pipe, state: state)
        let item = try #require(history.items.first)
        #expect(item.cleanedText == "cleaned")
        #expect(item.rawTranscript == "hello world")
    }
```

- [ ] **Step 3: Run to verify they fail**

```bash
xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/DictationHistoryStoreTests 2>&1 | grep -E "error:|passed|failed" | head -3
```
Expected: compile error, `extra argument 'rawTranscript' in call`.

- [ ] **Step 4: Implement in the store**

In `voxline/Storage/DictationHistoryStore.swift`:

Add to `DictationHistoryItem`, after `let appBundleID: String?`:
```swift
    /// What Whisper heard, before cleanup. Nil for rows written before 0.4.0.
    let rawTranscript: String?
```

Replace the `record` signature and the item construction:
```swift
    func record(cleanedText: String, rawTranscript: String? = nil, mode: Mode, context: CapturedContext) {
        guard !cleanedText.isBlank else { return }
        let item = DictationHistoryItem(
            id: UUID(),
            timestamp: Date(),
            cleanedText: cleanedText,
            modeCategoryName: mode.category.displayName,
            appName: context.appName,
            appBundleID: context.bundleID,
            rawTranscript: rawTranscript
        )
```

In `updateMostRecent`, add `rawTranscript: current.rawTranscript` as the last argument of the `DictationHistoryItem(` construction.

Update the doc comment on `DictationHistoryItem` so it no longer says `no raw transcript`:
```swift
/// One entry in the dictation history: the cleaned text that was inserted
/// plus the raw transcript it came from, so "was it the engine or the
/// cleanup?" is answerable from the History window. No audio, no model.
```

- [ ] **Step 5: Pass the transcript from the pipeline**

In `voxline/Pipeline/CapturePipeline.swift`:
- dictation path: `historyStore.record(cleanedText: cleaned, mode: mode, context: context)` → `historyStore.record(cleanedText: cleaned, rawTranscript: transcript, mode: mode, context: context)`
- transform path: `historyStore.record(cleanedText: transformed, mode: mode, context: context)` → `historyStore.record(cleanedText: transformed, rawTranscript: command, mode: mode, context: context)`

- [ ] **Step 6: Show it in the History window**

In `voxline/UI/HistoryView.swift`, inside `table`, insert a new column between `App` and `Preview`:

```swift
            TableColumn("Transcript") { item in
                Text(HistoryViewFormatter.previewText(item.rawTranscript ?? "—", maxChars: 120))
                    .foregroundStyle(.secondary)
                    .help(Self.tooltip(item))
            }
            .width(min: 160, ideal: 240)
```

Change the Preview column's width to `.width(min: 200, ideal: 360)` and the window's `.frame(minWidth: 760, minHeight: 320)` to `.frame(minWidth: 900, minHeight: 320)`.

Replace `tooltip(_:)` with:
```swift
    private static func tooltip(_ item: DictationHistoryItem) -> String {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .medium
        var text = "\(df.string(from: item.timestamp))\n\n\(item.cleanedText)"
        if let raw = item.rawTranscript, !raw.isEmpty {
            text += "\n\nRaw transcript:\n\(raw)"
        }
        return text
    }
```

- [ ] **Step 7: Run the tests**

```bash
xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/DictationHistoryStoreTests -only-testing:voxlineTests/CapturePipelineTests -only-testing:voxlineTests/HistoryViewFormatterTests 2>&1 | grep -E "error:|passed|failed" | tail -3
```
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add voxline/Storage/DictationHistoryStore.swift voxline/UI/HistoryView.swift voxline/Pipeline/CapturePipeline.swift voxlineTests/DictationHistoryStoreTests.swift voxlineTests/CapturePipelineTests.swift
git commit -s -m "feat(history): keep the raw transcript next to the cleaned text

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 9: Per-dictation metrics, logged and shown in About

**Files:**
- Create: `voxline/Diagnostics/DictationMetrics.swift`
- Create: `voxline/UI/DiagnosticsView.swift`
- Create: `voxlineTests/DictationMetricsStoreTests.swift`
- Modify: `voxline/Diagnostics/AppLog.swift`
- Modify: `voxline/Pipeline/PipelineProtocols.swift`, `voxline/Transcription/TranscriptionService.swift`
- Modify: `voxline/Pipeline/CapturePipeline.swift`
- Modify: `voxline/UI/AboutView.swift`, `voxline/UI/AboutWindowController.swift`, `voxline/voxlineApp.swift`
- Test: `voxlineTests/CapturePipelineTests.swift`

**Interfaces:**
- Produces:
  - `struct DictationMetrics: Equatable, Sendable` with `timestamp: Date`, `kind: Kind` (`.dictation` / `.command`), `audioDuration: TimeInterval`, `captureTailMs`, `transcribeMs`, `cleanupMs`, `insertMs`, `totalMs: Int`, `engineID`, `modelID: String`, `wordCount: Int`.
  - `@Observable @MainActor final class DictationMetricsStore` with `static let capacity = 50`, `private(set) var items: [DictationMetrics]` (newest first), `func record(_:)`, `func median(_ keyPath: KeyPath<DictationMetrics, Int>) -> Int?`.
  - `Transcribing.engineID: String` requirement with a protocol-extension default of `"unknown"`; `TranscriptionService.engineID` returns `"whisperkit:<variant>"`.
  - `CapturePipeline.metrics: DictationMetricsStore` (internal, readable by tests) and init parameters `metrics: DictationMetricsStore = DictationMetricsStore()`, `llmModelID: @escaping @Sendable () -> String = { AppSettings().llmModel }`.
  - `AppLog.metrics` logger category.
  - `DiagnosticsView(metrics:)`; `AboutView(env:metrics:)`; `AboutWindowController.show(env:metrics:)`.

- [ ] **Step 1: Write the failing store tests**

Create `voxlineTests/DictationMetricsStoreTests.swift`:

```swift
import Testing
import Foundation
@testable import voxline

@Suite @MainActor struct DictationMetricsStoreTests {

    private func metrics(total: Int, transcribe: Int = 0) -> DictationMetrics {
        DictationMetrics(
            timestamp: Date(), kind: .dictation, audioDuration: 1.0,
            captureTailMs: 0, transcribeMs: transcribe, cleanupMs: 0, insertMs: 0, totalMs: total,
            engineID: "test", modelID: "test-model", wordCount: 3
        )
    }

    @Test func record_keepsNewestFirst_andCapsAtCapacity() {
        let store = DictationMetricsStore()
        for i in 0..<(DictationMetricsStore.capacity + 5) {
            store.record(metrics(total: i))
        }
        #expect(store.items.count == DictationMetricsStore.capacity)
        #expect(store.items.first?.totalMs == DictationMetricsStore.capacity + 4)
        #expect(store.items.last?.totalMs == 5)
    }

    @Test func median_isNilWhenEmpty() {
        #expect(DictationMetricsStore().median(\.totalMs) == nil)
    }

    @Test func median_oddCount_isMiddleValue() {
        let store = DictationMetricsStore()
        for t in [900, 100, 500] { store.record(metrics(total: t)) }
        #expect(store.median(\.totalMs) == 500)
    }

    @Test func median_evenCount_averagesTheMiddlePair() {
        let store = DictationMetricsStore()
        for t in [100, 400, 200, 300] { store.record(metrics(total: t)) }
        #expect(store.median(\.totalMs) == 250)
    }

    @Test func median_followsTheRequestedField() {
        let store = DictationMetricsStore()
        store.record(metrics(total: 1000, transcribe: 10))
        store.record(metrics(total: 2000, transcribe: 30))
        store.record(metrics(total: 3000, transcribe: 20))
        #expect(store.median(\.transcribeMs) == 20)
    }
}
```

- [ ] **Step 2: Write the failing pipeline test**

Append inside the `@Suite` in `voxlineTests/CapturePipelineTests.swift`:

```swift
    @Test func finalize_success_recordsOneMetricsRow() async throws {
        let (pipe, state, _, _, _, _, _, _, _) = makePipeline()
        await startAndFinalize(pipe, state: state)
        let row = try #require(pipe.metrics.items.first)
        #expect(pipe.metrics.items.count == 1)
        #expect(row.kind == .dictation)
        #expect(row.wordCount == 1)
        #expect(row.engineID == "unknown")
        #expect(row.totalMs >= row.transcribeMs + row.cleanupMs)
    }

    @Test func finalize_llmFailure_recordsNoMetrics() async {
        let (pipe, state, _, _, llm, _, _, _, _) = makePipeline()
        llm.nextResult = .failure(LLMError.rateLimited)
        pipe.transcriptFallback = { _ in }
        await startAndFinalize(pipe, state: state)
        #expect(pipe.metrics.items.isEmpty)
    }
```

- [ ] **Step 3: Run to verify they fail**

```bash
xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/DictationMetricsStoreTests 2>&1 | grep -E "error:|passed|failed" | head -3
```
Expected: compile error, `cannot find 'DictationMetricsStore' in scope`.

- [ ] **Step 4: Add the log category**

In `voxline/Diagnostics/AppLog.swift`, add after the `updates` line:

```swift
    static let metrics     = Logger(subsystem: subsystem, category: "metrics")
```

- [ ] **Step 5: Implement the record and the store**

Create `voxline/Diagnostics/DictationMetrics.swift`:

```swift
import Foundation
import Observation

/// Timing breakdown of one dictation or command, from key release to text in
/// the field. Phase 2's latency targets are set against medians of these.
struct DictationMetrics: Equatable, Sendable {

    enum Kind: String, Sendable {
        case dictation
        case command
    }

    let timestamp: Date
    let kind: Kind
    let audioDuration: TimeInterval
    /// Key release → last audio sample drained. Near zero until streaming lands in phase 2.
    let captureTailMs: Int
    let transcribeMs: Int
    let cleanupMs: Int
    let insertMs: Int
    /// Key release → text in the field.
    let totalMs: Int
    let engineID: String
    let modelID: String
    let wordCount: Int
}

@Observable
@MainActor
final class DictationMetricsStore {

    static let capacity = 50

    private(set) var items: [DictationMetrics] = []

    func record(_ metrics: DictationMetrics) {
        items.insert(metrics, at: 0)
        if items.count > Self.capacity {
            items.removeLast(items.count - Self.capacity)
        }
        AppLog.metrics.info(
            "\(metrics.kind.rawValue, privacy: .public) audio=\(String(format: "%.1f", metrics.audioDuration), privacy: .public)s tail=\(metrics.captureTailMs)ms transcribe=\(metrics.transcribeMs)ms cleanup=\(metrics.cleanupMs)ms insert=\(metrics.insertMs)ms total=\(metrics.totalMs)ms engine=\(metrics.engineID, privacy: .public) model=\(metrics.modelID, privacy: .public) words=\(metrics.wordCount)"
        )
    }

    func median(_ keyPath: KeyPath<DictationMetrics, Int>) -> Int? {
        let values = items.map { $0[keyPath: keyPath] }.sorted()
        guard !values.isEmpty else { return nil }
        let mid = values.count / 2
        return values.count.isMultiple(of: 2) ? (values[mid - 1] + values[mid]) / 2 : values[mid]
    }
}
```

- [ ] **Step 6: Give the transcriber an engine id**

In `voxline/Pipeline/PipelineProtocols.swift`, replace the `Transcribing` protocol with:

```swift
@MainActor
protocol Transcribing: AnyObject {
    /// Stable identifier of the engine and model producing transcripts, for
    /// metrics. Phase 2's engine protocol replaces this.
    var engineID: String { get }
    /// Transcribe a Float32 PCM buffer at AudioFormat.whisperSampleRate.
    /// Vocabulary biasing happens later in the pipeline via the LLM cleanup
    /// prompt — see `LLMService.transcriptionPreamble`.
    func transcribe(samples: [Float]) async throws -> String
}

extension Transcribing {
    var engineID: String { "unknown" }
}
```

In `voxline/Transcription/TranscriptionService.swift`, add inside the class after `private var whisperKit: WhisperKit?`:

```swift
    var engineID: String { "whisperkit:\(model.whisperKitIdentifier)" }
```

- [ ] **Step 7: Record from the pipeline**

In `voxline/Pipeline/CapturePipeline.swift`:

Add two stored properties after `private let now: @Sendable () -> Date`:
```swift
    let metrics: DictationMetricsStore
    private let llmModelID: @Sendable () -> String
```

Add two init parameters after `selectionSnapshot: SelectionSnapshotting = DefaultSelectionSnapshot(),`:
```swift
        metrics: DictationMetricsStore = DictationMetricsStore(),
        llmModelID: @escaping @Sendable () -> String = { AppSettings().llmModel },
```
and the assignments after `self.selectionSnapshot = selectionSnapshot`:
```swift
        self.metrics = metrics
        self.llmModelID = llmModelID
```

Replace `finalizeRecording()` in full (this is the final form, including Task 7's no-field guard and Task 8's raw transcript):

```swift
    /// Stop capture, transcribe, run LLM cleanup against the active mode's
    /// prompt, and paste the result into the focused field.
    func finalizeRecording() async {
        // Only valid entry state is `.recording`. A spurious finalize while
        // we're already in `.thinking` (an earlier finalize is mid-flight) or
        // any non-recording state would race with the in-flight pipeline.
        guard case .recording = state.status else { return }
        let finalizeStart = Date()
        capture.stop()
        let samples = capture.takeSamples()
        let timing = PipelineTiming(finalizeStart: finalizeStart, captureTailMs: Self.milliseconds(since: finalizeStart))
        state.status = .thinking
        state.lastRecordingDuration = Double(samples.count) / 16_000.0

        // Silent-capture detector: tap fired (samples non-empty) but no audio
        // signal reached the converter (peak stayed at 0). Almost always means
        // Microphone permission is denied or a muted device was selected.
        if !samples.isEmpty && state.lastPeakLevel == 0 {
            cancelContextTask()
            return setError("No audio captured. Check that Microphone permission is granted and the input device isn't muted.")
        }

        if samples.isEmpty {
            cancelContextTask()
            resetIdle()
            return
        }

        // 1. Transcribe locally.
        let transcript: String
        let transcribeStart = Date()
        do {
            transcript = try await transcriber.transcribe(samples: samples)
        } catch {
            cancelContextTask()
            return setError("Transcription failed. Try again or pick a different model in Settings → General.")
        }
        state.lastTranscribeDuration = Date().timeIntervalSince(transcribeStart)
        state.lastTranscript = transcript

        if transcript.isEmpty {
            // Nothing to clean / paste — quietly idle out.
            cancelContextTask()
            resetIdle()
            return
        }

        // 2. Resolve the active mode by frontmost bundle ID + focused field
        //    snapshot. Falls back to `*` wildcard when nothing matches.
        let bundleID = frontmost.frontmostBundleID()
        let field = fieldInspector.inspect()
        guard let mode = modes.mode(for: bundleID, field: field) else {
            cancelContextTask()
            return setError("No mode for app '\(bundleID ?? "unknown")' and no '*' fallback configured. Open Settings → Modes.")
        }

        // 3. Route by mode. `recordingIsCommand` was latched at recording start.
        let context = await contextTask?.value ?? .empty
        contextTask = nil
        if state.recordingIsCommand {
            let selection = await selectionTask?.value ?? nil
            selectionTask = nil
            guard let selection, !selection.isEmpty else {
                // Command gesture but nothing selected: keep the mode boundary
                // crisp — no dictation fallback, no clipboard-probe surprise.
                resetIdle()
                showToast("Select text to transform")
                return
            }
            await performTransform(command: transcript, selection: selection, mode: mode, context: context, timing: timing)
            return
        }
        // Dictation path: selectionTask was never spawned, so the clipboard was
        // never touched.
        if !context.captureNotes.isEmpty {
            AppLog.context.info("context partial: notes=\(context.captureNotes.joined(separator: ",")) durationMs=\(context.captureDurationMs)")
        }
        let cleaned: String
        let cleanupStart = Date()
        do {
            cleaned = try await llm.cleanup(transcript: transcript, mode: mode, context: context, refinement: nil)
        } catch let e as LLMError {
            transcriptFallback(transcript)
            return setError("\(e.errorDescription ?? "LLM cleanup failed.") Raw transcript copied to the clipboard — paste to recover it.")
        } catch {
            transcriptFallback(transcript)
            return setError("LLM cleanup failed: \(error.localizedDescription) Raw transcript copied to the clipboard — paste to recover it.")
        }
        state.lastCleanupDuration = Date().timeIntervalSince(cleanupStart)
        state.lastCleanedText = cleaned
        historyStore.record(cleanedText: cleaned, rawTranscript: transcript, mode: mode, context: context)
        let cleanupMs = Self.milliseconds(state.lastCleanupDuration)

        guard field?.isEditable ?? true else {
            transcriptFallback(cleaned)
            recordMetrics(kind: .dictation, timing: timing, cleanupMs: cleanupMs, insertMs: 0, mode: mode, text: cleaned)
            resetIdle()
            showToast("No text field focused — copied")
            return
        }

        // 4. Paste.
        let insertStart = Date()
        do {
            _ = try await injector.inject(cleaned)
        } catch let e as TextInsertionError {
            return setError(e.errorDescription ?? "Text insertion failed.", permissions: e == .accessibilityNotGranted)
        } catch {
            return setError("Text insertion failed: \(error.localizedDescription)")
        }
        recordMetrics(kind: .dictation, timing: timing, cleanupMs: cleanupMs, insertMs: Self.milliseconds(since: insertStart), mode: mode, text: cleaned)

        // Offer quick refinements: keep the pill alive for a few seconds.
        startReviewSession(kind: .dictation, transcript: transcript, mode: mode, context: context, insertedText: cleaned)
        resetIdle()
    }
```

Replace `performTransform` in full:

```swift
    /// Rewrite the user's selection according to the spoken command, paste it
    /// over the (still-live) selection, and open a transform review session.
    /// Owns its terminal state — callers must not call `resetIdle` afterward.
    private func performTransform(command: String, selection: String, mode: Mode, context: CapturedContext, timing: PipelineTiming) async {
        // The AX reader returns the FULL live selection (no truncation), and
        // `injector.inject` below pastes back over that same full live
        // selection. If we let an over-long selection through, the LLM would
        // only see/rewrite the first `selectionMax` characters while the
        // paste still overwrites the entire selection — silently dropping
        // the untransformed tail. Refuse instead of desyncing read/write.
        guard selection.count <= DefaultSelectionSnapshot.selectionMax else {
            resetIdle()
            showToast("Selection too long to transform")
            return
        }

        let transformed: String
        let transformStart = Date()
        do {
            transformed = try await llm.transform(instruction: command, selection: selection, mode: mode)
        } catch let e as LLMError {
            return setError("\(e.errorDescription ?? "Transform failed.") Your selection was left unchanged.")
        } catch {
            return setError("Transform failed: \(error.localizedDescription) Your selection was left unchanged.")
        }
        let cleanupMs = Self.milliseconds(since: transformStart)

        // Focus/selection may have moved during the LLM await. If the live
        // selection no longer matches what we transformed, don't overwrite
        // the wrong target — leave the result on the clipboard for a manual
        // paste instead.
        guard await selectionSnapshot.readSelection() == selection else {
            transcriptFallback(transformed)
            resetIdle()
            showToast("Copied — ⌘V to replace")
            return
        }

        // The transform prompt returns the selection verbatim when the command
        // can't be applied as a rewrite/restructure (e.g. a translate request).
        // Treat that as a no-op rather than re-pasting identical text.
        guard !transformed.isEmpty, transformed != selection else {
            resetIdle()
            showToast("Couldn't apply that")
            return
        }

        historyStore.record(cleanedText: transformed, rawTranscript: command, mode: mode, context: context)

        let insertStart = Date()
        do {
            // Selection is live, so a paste lands over it — no re-selection needed.
            _ = try await injector.inject(transformed)
        } catch {
            // Any insertion failure: leave the result on the clipboard so ⌘V
            // still replaces the selection.
            transcriptFallback(transformed)
            recordMetrics(kind: .command, timing: timing, cleanupMs: cleanupMs, insertMs: 0, mode: mode, text: transformed)
            startReviewSession(kind: .transform, transcript: command, mode: mode, context: context, insertedText: transformed)
            resetIdle()
            showToast("Copied — ⌘V to replace")
            return
        }
        recordMetrics(kind: .command, timing: timing, cleanupMs: cleanupMs, insertMs: Self.milliseconds(since: insertStart), mode: mode, text: transformed)

        startReviewSession(kind: .transform, transcript: command, mode: mode, context: context, insertedText: transformed)
        resetIdle()
    }
```

Add these helpers at the bottom of the class, above `private func showToast`:

```swift
    private struct PipelineTiming {
        let finalizeStart: Date
        let captureTailMs: Int
    }

    private func recordMetrics(kind: DictationMetrics.Kind, timing: PipelineTiming, cleanupMs: Int, insertMs: Int, mode: Mode, text: String) {
        metrics.record(DictationMetrics(
            timestamp: now(),
            kind: kind,
            audioDuration: state.lastRecordingDuration ?? 0,
            captureTailMs: timing.captureTailMs,
            transcribeMs: Self.milliseconds(state.lastTranscribeDuration),
            cleanupMs: cleanupMs,
            insertMs: insertMs,
            totalMs: Self.milliseconds(since: timing.finalizeStart),
            engineID: transcriber.engineID,
            modelID: mode.model ?? llmModelID(),
            wordCount: text.split(whereSeparator: \.isWhitespace).count
        ))
    }

    private static func milliseconds(_ interval: TimeInterval?) -> Int {
        Int(((interval ?? 0) * 1000).rounded())
    }

    private static func milliseconds(since start: Date) -> Int {
        milliseconds(Date().timeIntervalSince(start))
    }
```

- [ ] **Step 8: Show the numbers in About**

Create `voxline/UI/DiagnosticsView.swift`:

```swift
import SwiftUI

/// Latency breakdown of the last dictation and medians over the retained
/// history. Lives in the About window so bug reports can quote it.
struct DiagnosticsView: View {
    let metrics: DictationMetricsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Diagnostics")
                .fontWeight(.semibold)
            if let last = metrics.items.first {
                Text("Last: \(Self.line(total: last.totalMs, transcribe: last.transcribeMs, cleanup: last.cleanupMs, insert: last.insertMs))")
                if let total = metrics.median(\.totalMs),
                   let transcribe = metrics.median(\.transcribeMs),
                   let cleanup = metrics.median(\.cleanupMs),
                   let insert = metrics.median(\.insertMs) {
                    Text("Median of \(metrics.items.count): \(Self.line(total: total, transcribe: transcribe, cleanup: cleanup, insert: insert))")
                }
                Text("Engine \(last.engineID) · Model \(last.modelID)")
            } else {
                Text("No dictations yet.")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func line(total: Int, transcribe: Int, cleanup: Int, insert: Int) -> String {
        "\(seconds(total)) total · transcribe \(seconds(transcribe)) · cleanup \(seconds(cleanup)) · insert \(seconds(insert))"
    }

    static func seconds(_ milliseconds: Int) -> String {
        String(format: "%.2fs", Double(milliseconds) / 1000)
    }
}
```

In `voxline/UI/AboutView.swift`:
- add `var metrics: DictationMetricsStore? = nil` after `let env: SupportEnvironment`,
- insert directly after the `.controlSize(.large)` line of the button stack:
  ```swift
            if let metrics {
                DiagnosticsView(metrics: metrics)
            }
  ```
- change `.frame(width: 320, height: 420)` to `.frame(width: 320, height: 500)`.

In `voxline/UI/AboutWindowController.swift`:
- change the signature to `func show(env: SupportEnvironment, metrics: DictationMetricsStore? = nil)`,
- `AboutView(env: env)` → `AboutView(env: env, metrics: metrics)`,
- `height: 420` → `height: 500`.

In `voxline/voxlineApp.swift`, `AppDelegate.showAboutWindow`, change `aboutWindow.show(env: env)` to:
```swift
        aboutWindow.show(env: env, metrics: coordinator.pipeline?.metrics)
```

- [ ] **Step 9: Run the tests**

```bash
xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' 2>&1 | grep -E "BUILD|error:|passed|failed" | tail -4
```
Expected: build succeeds, all suites pass including `DictationMetricsStoreTests` (5) and the two new pipeline tests.

- [ ] **Step 10: Commit**

```bash
git add voxline/Diagnostics voxline/UI/DiagnosticsView.swift voxline/UI/AboutView.swift voxline/UI/AboutWindowController.swift voxline/voxlineApp.swift voxline/Pipeline voxline/Transcription/TranscriptionService.swift voxlineTests/DictationMetricsStoreTests.swift voxlineTests/CapturePipelineTests.swift
git commit -s -m "feat(diagnostics): record per-dictation latency and show it in About

Transcribe, cleanup, insert, and release-to-text totals for the last 50
dictations, with medians. This is the baseline phase 2 is measured against.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 10: Keychain read errors are errors, and never cause a delete

**Files:**
- Modify: `voxline/Storage/DataProtectionKeychain.swift`
- Modify: `voxline/Settings/APIKeysSettingsViewModel.swift`
- Modify: `voxlineTests/InMemoryKeychain.swift`
- Test: `voxlineTests/APIKeysSettingsViewModelTests.swift`, `voxlineTests/WizardViewModelTests.swift`

**Interfaces:**
- `DataProtectionKeychain.string(forKey:)` now throws `KeychainError.dataProtectionKeychainUnavailable` on `errSecMissingEntitlement` instead of returning nil.
- `APIKeysSettingsViewModel`: a failed read leaves the field empty, sets `lastError`, and makes an empty commit for that account a no-op until a non-empty save succeeds. `WizardViewModel.commitProgress()` inherits this through `commitAnthropic()` / `commitOpenAI()`.
- Test double: `InMemoryKeychain.readError: Error?` — when set, `string(forKey:)` throws it.

- [ ] **Step 1: Extend the test double**

In `voxlineTests/InMemoryKeychain.swift`, add a property after `private var storage`:
```swift
    /// When set, every read throws it. Simulates a keychain that is present
    /// but unreadable (broken entitlement, locked store).
    var readError: Error?
```
and make `string(forKey:)` start with:
```swift
        if let readError { throw readError }
```

- [ ] **Step 2: Write the failing view-model tests**

Append inside the `@Suite` in `voxlineTests/APIKeysSettingsViewModelTests.swift`:

```swift
    @Test func read_failure_leaves_field_empty_and_reports() {
        let kc = keychain()
        kc.readError = KeychainError.dataProtectionKeychainUnavailable
        let vm = APIKeysSettingsViewModel(keychain: kc)
        #expect(vm.anthropicKey == "")
        #expect(vm.openaiKey == "")
        #expect(vm.lastError?.lowercased().contains("keychain") == true)
    }

    @Test func empty_commit_after_read_failure_keeps_stored_key() throws {
        let kc = keychain()
        try kc.set("sk-real", forKey: KeychainAccount.anthropic)
        kc.readError = KeychainError.dataProtectionKeychainUnavailable
        let vm = APIKeysSettingsViewModel(keychain: kc)

        vm.commitAnthropic()

        kc.readError = nil
        #expect(try kc.string(forKey: KeychainAccount.anthropic) == "sk-real")
    }

    @Test func typed_key_after_read_failure_saves_and_reenables_delete() throws {
        let kc = keychain()
        kc.readError = KeychainError.dataProtectionKeychainUnavailable
        let vm = APIKeysSettingsViewModel(keychain: kc)
        vm.anthropicKey = "sk-new"
        vm.commitAnthropic()
        kc.readError = nil
        #expect(try kc.string(forKey: KeychainAccount.anthropic) == "sk-new")

        vm.anthropicKey = ""
        vm.commitAnthropic()
        #expect(try kc.string(forKey: KeychainAccount.anthropic) == nil)
    }
```

Append inside the `@Suite` in `voxlineTests/WizardViewModelTests.swift`:

```swift
    @Test func advance_with_unreadable_keychain_keeps_existing_keys() throws {
        let kc = InMemoryKeychain()
        try kc.set("sk-ant-real", forKey: KeychainAccount.anthropic)
        try kc.set("sk-oa-real", forKey: KeychainAccount.openai)
        kc.readError = KeychainError.dataProtectionKeychainUnavailable
        let vm = WizardViewModel(settings: AppSettings(defaults: defaults()), keychain: kc)

        vm.advance()
        vm.advance()

        kc.readError = nil
        #expect(try kc.string(forKey: KeychainAccount.anthropic) == "sk-ant-real")
        #expect(try kc.string(forKey: KeychainAccount.openai) == "sk-oa-real")
    }
```

- [ ] **Step 3: Run to verify they fail**

```bash
xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/APIKeysSettingsViewModelTests -only-testing:voxlineTests/WizardViewModelTests 2>&1 | grep -E "error:|passed|failed" | head -5
```
Expected: `empty_commit_after_read_failure_keeps_stored_key` and `advance_with_unreadable_keychain_keeps_existing_keys` fail (the key was deleted); `read_failure_leaves_field_empty_and_reports` fails on `lastError` being nil.

- [ ] **Step 4: Make the production keychain throw on a read it cannot perform**

In `voxline/Storage/DataProtectionKeychain.swift`, `string(forKey:)`, replace:
```swift
        case errSecMissingEntitlement:
            Self.log.error("DPK read missing entitlement; treating account=\(account) as absent")
            return nil
```
with:
```swift
        case errSecMissingEntitlement:
            Self.log.error("DPK read rejected: missing entitlement (signing broken or unsigned build)")
            throw KeychainError.dataProtectionKeychainUnavailable
```

- [ ] **Step 5: Track read failures in the view model**

In `voxline/Settings/APIKeysSettingsViewModel.swift`:

Add after `private var openaiPersisted: String = ""`:
```swift
    private var anthropicReadFailed = false
    private var openaiReadFailed = false
```

Replace the body of `init(keychain:clientFactory:)` with:
```swift
        self.keychain = keychain
        self.clientFactory = clientFactory
        let anthropic = Self.load(KeychainAccount.anthropic, from: keychain)
        let openai = Self.load(KeychainAccount.openai, from: keychain)
        self.anthropicKey = anthropic.value
        self.openaiKey = openai.value
        self.anthropicPersisted = anthropic.value
        self.openaiPersisted = openai.value
        self.anthropicReadFailed = anthropic.failed
        self.openaiReadFailed = openai.failed
        if anthropic.failed || openai.failed {
            self.lastError = "Couldn't read the saved API keys from the keychain. They were left untouched — relaunch and try again."
        }
```

Add after the init:
```swift
    private static func load(_ account: String, from keychain: any KeychainStorage) -> (value: String, failed: Bool) {
        do {
            return (try keychain.string(forKey: account) ?? "", false)
        } catch {
            AppLog.llm.error("keychain read failed for \(account, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return ("", true)
        }
    }
```

Replace `persist(value:account:)` with:
```swift
    /// An empty value deletes the entry — unless the entry could not be read
    /// at load time, in which case deleting would destroy a key the user
    /// never saw. A successful non-empty save clears that guard.
    private func persist(value: String, account: String) {
        let v = value.trimmed
        if v.isEmpty && readFailed(for: account) { return }
        do {
            if v.isEmpty {
                try keychain.delete(forKey: account)
            } else {
                try keychain.set(v, forKey: account)
            }
            setReadFailed(false, for: account)
        } catch {
            lastError = "Save failed: \(error.localizedDescription)"
        }
    }

    private func readFailed(for account: String) -> Bool {
        account == KeychainAccount.anthropic ? anthropicReadFailed : openaiReadFailed
    }

    private func setReadFailed(_ failed: Bool, for account: String) {
        if account == KeychainAccount.anthropic {
            anthropicReadFailed = failed
        } else {
            openaiReadFailed = failed
        }
    }
```

- [ ] **Step 6: Run the tests**

```bash
xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/APIKeysSettingsViewModelTests -only-testing:voxlineTests/WizardViewModelTests -only-testing:voxlineTests/DataProtectionKeychainTests 2>&1 | grep -E "error:|passed|failed" | tail -3
```
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add voxline/Storage/DataProtectionKeychain.swift voxline/Settings/APIKeysSettingsViewModel.swift voxlineTests/InMemoryKeychain.swift voxlineTests/APIKeysSettingsViewModelTests.swift voxlineTests/WizardViewModelTests.swift
git commit -s -m "fix(keychain): surface read failures and never delete a key over one

A missing-entitlement read used to look like \"no key configured\"; the
wizard then committed the empty field and deleted the real key.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 11: Dev scripts, manual test checklist, and docs

**Files:**
- Modify: `scripts/reset-local-state.sh` (full rewrite below)
- Modify: `scripts/tail-logs.sh` (category list)
- Modify: `docs/release/MANUAL_TESTS.md` (new section)
- Modify: `README.md`, `AGENTS.md`, `CHANGELOG.md`

- [ ] **Step 1: Rewrite reset-local-state.sh for the new paths**

Replace `scripts/reset-local-state.sh` in full:

```bash
#!/usr/bin/env bash
# Reset voxline local state so the next launch behaves like a brand-new install.
#
# Wipes:
#   - ~/Library/Application Support/voxline (custom modes, Whisper model cache)
#   - The com.voxline.app defaults domain (settings, history, first-run flag)
#   - ~/Library/Caches/com.voxline.app (ANE compiled bundle)
#   - Any leftover 0.3.x sandbox container Data/
#   - Keychain entries for Anthropic + OpenAI API keys
#   - Stray voxline-status-test-*.plist files from past test runs
#
# Preserves by default:
#   - The custom vocabulary list. Re-entering vocab on every reset is tedious;
#     pass --wipe-vocab to clear it too.
#
# Optional flags:
#   --keep-model      Preserve the cached Whisper model AND the ANE compiled
#                     bundle so the next launch doesn't re-download the model
#                     or pay the 30s-2min ANE recompile. Everything else
#                     (settings, history, keychain, etc.) is still wiped.
#   --wipe-vocab      Also wipe the custom vocabulary list (default is to
#                     preserve it across resets).
#   --reset-tcc       Also reset macOS privacy prompts (mic, accessibility,
#                     input monitoring) so the OS re-asks on next launch.
#   --reset-keys      Accepted for explicitness. Keychain clearing is part of
#                     the default behavior; this flag is a no-op.
#   -h, --help        Show this help.

set -euo pipefail

BUNDLE_ID="com.voxline.app"
KEYCHAIN_SERVICE="com.voxline.app.keys"
APP_SUPPORT="$HOME/Library/Application Support/voxline"
HF_MODEL_PATH="$APP_SUPPORT/huggingface"
CACHES_DIR="$HOME/Library/Caches/$BUNDLE_ID"
ANE_BUNDLE_PATH="$CACHES_DIR/com.apple.e5rt.e5bundlecache"
LEGACY_CONTAINER_DATA="$HOME/Library/Containers/$BUNDLE_ID/Data"
# plutil treats `.` in keypaths as nested-dict separators. The actual top-level
# UserDefaults key contains dots, so each one has to be backslash-escaped when
# passed to `plutil -extract`/`-insert`. Key must match CustomVocabularyStore.
VOCAB_KEY='voxline\.context\.customVocabulary'

KEEP_MODEL=0
RESET_TCC=0
KEEP_VOCAB=1

for arg in "$@"; do
    case "$arg" in
        --keep-model) KEEP_MODEL=1 ;;
        --wipe-vocab) KEEP_VOCAB=0 ;;
        --reset-tcc)  RESET_TCC=1 ;;
        --reset-keys) ;; # no-op; keychain clearing is part of the default flow
        -h|--help)
            sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "unknown flag: $arg" >&2
            exit 2
            ;;
    esac
done

echo "→ Quitting voxline if running..."
osascript -e 'tell application "voxline" to quit' >/dev/null 2>&1 || true
sleep 1

# Stash the custom vocab before the wipe. `defaults export` goes through
# cfprefsd, so it sees the live domain rather than a possibly stale plist.
STASHED_VOCAB_PLIST=""
if [[ $KEEP_VOCAB -eq 1 ]]; then
    FULL_EXPORT=$(mktemp -t voxline-prefs).plist
    if defaults export "$BUNDLE_ID" "$FULL_EXPORT" 2>/dev/null; then
        STASHED_VOCAB_PLIST=$(mktemp -t voxline-vocab).plist
        if plutil -extract "$VOCAB_KEY" xml1 -o "$STASHED_VOCAB_PLIST" "$FULL_EXPORT" 2>/dev/null; then
            echo "→ Stashing custom vocabulary..."
        else
            rm -f "$STASHED_VOCAB_PLIST"
            STASHED_VOCAB_PLIST=""
            echo "→ No custom vocabulary to preserve."
        fi
    fi
    rm -f "$FULL_EXPORT"
fi

STASH=$(mktemp -d -t voxline-reset)
trap 'rm -rf "$STASH"' EXIT

if [[ $KEEP_MODEL -eq 1 ]]; then
    if [[ -d "$HF_MODEL_PATH" ]]; then
        echo "→ Stashing Whisper model cache..."
        mv "$HF_MODEL_PATH" "$STASH/huggingface"
    fi
    if [[ -d "$ANE_BUNDLE_PATH" ]]; then
        echo "→ Stashing ANE compiled-bundle cache..."
        mv "$ANE_BUNDLE_PATH" "$STASH/anebundle"
    fi
fi

echo "→ Clearing $APP_SUPPORT..."
rm -rf "$APP_SUPPORT"
echo "→ Clearing defaults domain $BUNDLE_ID..."
defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
echo "→ Clearing $CACHES_DIR..."
rm -rf "$CACHES_DIR"

# NOTE: wipe the legacy container's Data/ contents, not the container itself.
# containermanagerd protects the container directory and its metadata plist.
if [[ -d "$LEGACY_CONTAINER_DATA" ]]; then
    echo "→ Clearing leftover 0.3.x sandbox container Data/..."
    rm -rf "$LEGACY_CONTAINER_DATA"/* "$LEGACY_CONTAINER_DATA"/.[!.]* 2>/dev/null || true
fi

if [[ -d "$STASH/huggingface" ]]; then
    echo "→ Restoring Whisper model cache..."
    mkdir -p "$(dirname "$HF_MODEL_PATH")"
    mv "$STASH/huggingface" "$HF_MODEL_PATH"
fi
if [[ -d "$STASH/anebundle" ]]; then
    echo "→ Restoring ANE compiled-bundle cache..."
    mkdir -p "$(dirname "$ANE_BUNDLE_PATH")"
    mv "$STASH/anebundle" "$ANE_BUNDLE_PATH"
fi

# Restore vocab after the wipe. The stashed file is a standalone plist whose
# root element IS the vocab value. Strip the <plist> wrapper, insert it into a
# fresh plist under the real key, and import that through cfprefsd.
if [[ -n "$STASHED_VOCAB_PLIST" && -f "$STASHED_VOCAB_PLIST" ]]; then
    echo "→ Restoring custom vocabulary..."
    IMPORT_PLIST=$(mktemp -t voxline-import).plist
    plutil -create xml1 "$IMPORT_PLIST"
    inner_xml=$(awk '
        /<plist/ { flag=1; next }
        /<\/plist>/ { flag=0 }
        flag { print }
    ' "$STASHED_VOCAB_PLIST")
    plutil -insert "$VOCAB_KEY" -xml "$inner_xml" "$IMPORT_PLIST"
    defaults import "$BUNDLE_ID" "$IMPORT_PLIST"
    rm -f "$STASHED_VOCAB_PLIST" "$IMPORT_PLIST"
fi

echo "→ Deleting Keychain entries (service=$KEYCHAIN_SERVICE)..."
# Data-protection keychain (where current builds write). The `security` CLI
# can't reach DPK items — they're gated by the app's keychain-access-groups
# entitlement. Drive deletion through the signed app binary itself.
binary_can_reach_dpk() {
    local bin=$1
    [[ -x "$bin" ]] || return 1
    local app=${bin%/Contents/MacOS/voxline}
    codesign --verify --deep --strict "$app" 2>/dev/null || return 1
    codesign -dv "$app" 2>&1 | grep -q "TeamIdentifier=2B5FBFV6CF" || return 1
    return 0
}
find_app_binary() {
    local candidates=(
        "/Applications/voxline.app/Contents/MacOS/voxline"
        "$HOME/Applications/voxline.app/Contents/MacOS/voxline"
    )
    local dd
    dd=$(ls -td "$HOME/Library/Developer/Xcode/DerivedData"/voxline-*/Build/Products/Debug/voxline.app/Contents/MacOS/voxline 2>/dev/null | head -1)
    [[ -n "$dd" ]] && candidates+=("$dd")

    local skipped=()
    for c in "${candidates[@]}"; do
        if binary_can_reach_dpk "$c"; then
            echo "$c"
            (( ${#skipped[@]} )) && printf '   ⚠ skipped (bad signature): %s\n' "${skipped[@]}" >&2
            return 0
        elif [[ -x "$c" ]]; then
            skipped+=("$c")
        fi
    done
    (( ${#skipped[@]} )) && printf '   ⚠ skipped (bad signature): %s\n' "${skipped[@]}" >&2
    return 1
}
if app_bin=$(find_app_binary); then
    echo "   invoking $app_bin --reset-keys for data-protection keychain..."
    "$app_bin" --reset-keys 2>&1 | sed 's/^/   /'
else
    echo "   ⚠ no built voxline binary found — data-protection keychain entries"
    echo "     were NOT cleared. Build the app first, or remove items with service"
    echo "     '$KEYCHAIN_SERVICE' in Keychain Access by hand."
fi

echo "→ Cleaning stray voxline-status-test-*.plist files..."
shopt -s nullglob
stale=( "$HOME"/Library/Preferences/voxline-status-test-*.plist )
if (( ${#stale[@]} )); then
    rm -f "${stale[@]}"
    echo "   removed ${#stale[@]} file(s)."
else
    echo "   none found."
fi

if [[ $RESET_TCC -eq 1 ]]; then
    if [[ -z "${BUNDLE_ID:-}" ]]; then
        echo "✗ refusing to run --reset-tcc: BUNDLE_ID is empty." >&2
        exit 3
    fi
    echo "→ Resetting TCC privacy prompts for $BUNDLE_ID only..."
    for svc in Microphone ListenEvent Accessibility; do
        if tccutil reset "$svc" "$BUNDLE_ID" >/dev/null 2>&1; then
            echo "   reset:   $svc"
        else
            echo "   absent:  $svc (no entry for $BUNDLE_ID, or service name not recognized)"
        fi
    done
fi

echo "✓ Done. Next launch will run the first-run wizard."
```

Check it parses:
```bash
bash -n scripts/reset-local-state.sh && echo ok
```
Expected: `ok`.

- [ ] **Step 2: Teach tail-logs.sh the new category**

In `scripts/tail-logs.sh`:
- the header comment line `#   pipeline, hotkey, audio, whisper, llm, paste, context, permissions, keychain` → append `, metrics`
- in the awk `BEGIN` block, after `cat_c["keychain-migration"] = GRY`, add `cat_c["metrics"]            = YEL`.

- [ ] **Step 3: Add the manual checklist**

Append to `docs/release/MANUAL_TESTS.md`:

```markdown

# Manual test pass: 0.4.0 platform reset

Covers what XCTest cannot: the real container migration, real AX reads, and
Sparkle running unsandboxed.

## Upgrade from 0.3.1

- [ ] Install 0.3.1 from Releases. Complete the wizard, save an API key, add
      two custom vocabulary terms, dictate three times (so history is non-empty).
- [ ] Install 0.4.0 over it (DMG drag, or Sparkle from a staging appcast). Launch.
- [ ] No wizard appears. Settings → the hotkey, provider, and model are unchanged.
- [ ] Settings → API Keys shows the saved key (no re-entry).
- [ ] Custom vocabulary still lists both terms. Show history… lists the three dictations.
- [ ] No model download happens. `ls ~/Library/Application\ Support/voxline/huggingface/models/argmaxinc/whisperkit-coreml/` lists the variant.
- [ ] `ls ~/Library/Containers/com.voxline.app/Data/Documents/` no longer contains `huggingface`.
- [ ] `scripts/tail-logs.sh --last 2m pipeline` shows a `container migration:` line with `models=true`.

## Fresh install

- [ ] `scripts/reset-local-state.sh`, launch, complete the wizard, dictate into Notes.
- [ ] `defaults read com.voxline.app voxline.migration.containerMigrated` prints `1`.

## Accessibility reads work

- [ ] Run a Debug build with `VOXLINE_TRACE_LLM=1` from Xcode. Dictate into the
      middle of an existing paragraph in Notes. The trace's `textBeforeCursor`
      and `textAfterCursor` are populated (not `(nil)`).
- [ ] Select text in Notes, hold the dictation chord + command modifier, say
      "make this shorter". The selection is replaced. Repeat in Slack and in
      Gmail in Safari.

## No editable field

- [ ] Click the Finder desktop so nothing editable has focus. Dictate. The pill
      shows "No text field focused — copied"; ⌘V in Notes pastes the text.

## Diagnostics

- [ ] After three dictations, About Voxline shows a Diagnostics block with
      "Last:" and "Median of 3:" lines and non-zero transcribe/cleanup times.
- [ ] After 20 dictations, note the median total. Record it in the phase 2
      spec as the baseline.

## Entitlements and notarization

- [ ] `codesign -d --entitlements :- /Applications/voxline.app` lists exactly
      `com.apple.security.device.audio-input`, `keychain-access-groups`, and
      the signing-injected identifiers. No `app-sandbox`.
- [ ] `spctl -a -v /Applications/voxline.app` → `accepted source=Notarized Developer ID` (release build only).

## Sparkle unsandboxed

- [ ] Point a Debug build at a staging appcast with a newer version. Check for
      updates… installs and relaunches without an XPC or permission error.

## Hung target app

- [ ] Click into Slack's message box, then from Terminal run `kill -STOP $(pgrep -x Slack)`
      so the frozen app still owns keyboard focus. Hold the chord, speak, release.
      voxline must not beachball for more than a second (the AX timeout is 0.5s per
      request); the pill shows "No text field focused — copied" or an error within a
      few seconds. Run `kill -CONT $(pgrep -x Slack)` afterwards.
```

- [ ] **Step 4: Update README and AGENTS.md for the sandbox change**

`README.md`, "Good to know" list: replace the line beginning `- **Sandboxed app**` with:

```markdown
- **Not sandboxed, on purpose** — voxline reads the focused field through the Accessibility API, which the App Sandbox blocks. The app ships notarized with the hardened runtime, and its data lives in `~/Library/Application Support/voxline`.
```

`AGENTS.md`:
- replace the bullet beginning `- Sandboxed app (` with:
  ```markdown
  - Not sandboxed (hardened runtime only). App data lives in `~/Library/Application Support/voxline`; preferences in the standard defaults domain. `Storage/AppPaths.swift` owns every path and `Storage/ContainerMigration.swift` moves 0.3.x container data on first launch.
  ```
- replace `` - `voxlineTests/` — XCTest unit/integration tests `` with `` - `voxlineTests/` — Swift Testing unit/integration tests ``.
- in the `scripts/` bullets add: `` `scripts/tail-logs.sh` categories include `metrics` (per-dictation timings). ``

- [ ] **Step 5: Write the changelog entry**

In `CHANGELOG.md`, under `## [Unreleased]`, add:

```markdown
### Changed

- **voxline is no longer sandboxed.** The App Sandbox blocked reading the
  focused field through Accessibility, which forced clipboard tricks for
  selection reads and left cursor context empty. The app now ships with the
  hardened runtime only. On first launch it moves settings, history,
  vocabulary, custom modes, and the cached Whisper model out of the old
  container, so nothing re-downloads.
- **Minimum macOS is now 26.** Older systems stay on 0.3.1.
- Dictating with no editable field focused now says so and copies the text
  to the clipboard instead of reporting success.

### Added

- Per-dictation timing in About Voxline → Diagnostics: transcribe, cleanup,
  insert, and total, with medians over the last 50.
- History keeps the raw transcript next to the cleaned text.

### Fixed

- A hung target app can no longer stall voxline: every Accessibility request
  times out after half a second.
- A keychain read failure no longer looks like "no key configured", and the
  setup wizard can no longer delete saved keys over a transient read error.
```

- [ ] **Step 6: Commit**

```bash
git add scripts/reset-local-state.sh scripts/tail-logs.sh docs/release/MANUAL_TESTS.md README.md AGENTS.md CHANGELOG.md
git commit -s -m "docs: unsandboxed paths in dev scripts, 0.4.0 manual checklist, changelog

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 12: Release prep and baseline

**Files:**
- Modify: `voxline.xcodeproj/project.pbxproj` (four `MARKETING_VERSION` lines)
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Run the whole suite one more time**

```bash
xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' 2>&1 | grep -E "BUILD|passed|failed" | tail -3
```
Expected: all pass.

- [ ] **Step 2: Build, install, and run the manual checklist**

```bash
./scripts/build-local.sh
```
Then work through `docs/release/MANUAL_TESTS.md` → "Manual test pass: 0.4.0 platform reset". Every box must be ticked, including the 20-dictation baseline. Write the baseline median into `docs/superpowers/specs/2026-10-08-voxline-roadmap-design.md` under Phase 1 → "Done when", as a one-line note: `Baseline recorded <date>: median total <N> ms over 20 dictations on <Mac model>.`

- [ ] **Step 3: Bump the version and date the changelog**

```bash
sed -i '' 's/MARKETING_VERSION = 0.3.1;/MARKETING_VERSION = 0.4.0;/g' voxline.xcodeproj/project.pbxproj
grep -c "MARKETING_VERSION = 0.4.0;" voxline.xcodeproj/project.pbxproj
```
Expected: `4`.

In `CHANGELOG.md`, insert `## [0.4.0] - <today's date>` under `## [Unreleased]` so the entries written in Task 11 sit under the new heading, and add the compare links at the bottom:

```markdown
[Unreleased]: https://github.com/tfredricks/voxline/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/tfredricks/voxline/releases/tag/v0.4.0
```
(update the existing `[Unreleased]` link line rather than duplicating it).

- [ ] **Step 4: Commit**

```bash
git add voxline.xcodeproj/project.pbxproj CHANGELOG.md docs/superpowers/specs/2026-10-08-voxline-roadmap-design.md
git commit -s -m "release: prepare 0.4.0 — platform reset

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

Tagging (`git tag v0.4.0 && git push origin main --tags`) and the GitHub Release are the maintainer's manual steps per the README's release checklist. Do not tag from this plan.

---

## Self-review

**Spec coverage.** Entitlements and target → Task 1. Data migration → Tasks 3 and 4. Delete the workarounds → Tasks 5 and 6. Instrumentation (metrics record, log, last 50, About diagnostics, raw transcript in history) → Tasks 8 and 9. Issue 5 → Task 7. Issue 13 → Task 10. AppCoordinator extraction → Task 2. README/AGENTS/CHANGELOG/MANUAL_TESTS → Tasks 1 and 11. "Done when" checks → Task 12 via the manual checklist, including the baseline. Issue 9's AX timeout → Task 5.

**Known deviations from the spec, deliberate.** The spec's metrics table lists `captureTailMs` as release → last sample; in this non-streaming phase it is measured but near zero, and the field exists so phase 2 can fill it. The spec says "every AX element we create gets a messaging timeout"; one call on the system-wide element sets the process default for all of them, which is the same effect with less code.

**Type consistency check.** `ContainerMigration.Report` field names match between Task 4's implementation and tests. `DictationMetrics` memberwise order (`timestamp, kind, audioDuration, captureTailMs, transcribeMs, cleanupMs, insertMs, totalMs, engineID, modelID, wordCount`) is identical in the store tests and `recordMetrics`. `DictationHistoryStore.record(cleanedText:rawTranscript:mode:context:)` label order matches every call site in Tasks 8 and 9. `AboutWindowController.show(env:metrics:)` matches the `AppDelegate` call. `InMemoryKeychain.readError` is the name used by all three Task 10 tests.
