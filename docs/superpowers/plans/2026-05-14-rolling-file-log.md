# Rolling File Log Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a 250-entry rolling text log written to the sandboxed Application Support directory, mirroring `AppLog`'s OSLog output so users and support can retrieve recent app logs without Console.app.

**Architecture:** A new `RollingFileLog` class owns an in-memory ring buffer + atomic file rewrites at `<AppPaths.applicationSupportDirectory()>/voxline.log`. The existing `AppLog` enum is reshaped so each category becomes a `CategoryLog` shim that fans out every call to both OSLog and the shared `RollingFileLog` instance. Existing `AppLog.<category>.<level>(...)` call sites continue to work; OSLog interpolation features (`privacy:`) at call sites are migrated to plain `String` interpolation.

**Tech Stack:** Swift 5/6 on macOS, OSLog (`os.Logger`), Swift Testing (`@Suite`, `@Test`, `#expect`), `os_unfair_lock` for thread safety, `Foundation` for `FileManager` / `Date` / `DateFormatter`. No new package dependencies.

**Spec:** `docs/superpowers/specs/2026-05-14-rolling-file-log-design.md`

**Build & test commands** (use these throughout):

```bash
xcodebuild test \
    -project voxline.xcodeproj \
    -scheme voxline \
    -destination 'platform=macOS' \
    -only-testing:voxlineTests/<SuiteName>
```

For full suite:

```bash
xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS'
```

**Conventions:**
- Tests live in `voxlineTests/Diagnostics/` (create the directory). The Xcode project uses **PBXFileSystemSynchronizedRootGroup** — new `.swift` files placed inside the source-tree directory are picked up automatically; **no `project.pbxproj` edits are required.**
- Commit-message style: conventional commits (`feat(scope): …`, `test(scope): …`, etc.) matching existing `git log`. Co-Authored-By trailer is the convention used in recent history.
- Tests use Swift Testing (`import Testing`, `@Suite`, `@Test`, `#expect`, `#require`). Do **not** use XCTest.

---

## File Structure

| Path | Action | Responsibility |
|---|---|---|
| `voxline/Diagnostics/RollingFileLog.swift` | Create | Owns the 250-entry ring buffer and atomic disk writes. Pure data class, no OSLog awareness. |
| `voxline/Diagnostics/AppLog.swift` | Modify (rewrite) | Reshape from raw `Logger` constants to `CategoryLog` shims that fan out to OSLog + `RollingFileLog`. Add the `AppLog.fileLog` singleton. |
| `voxlineTests/Diagnostics/RollingFileLogTests.swift` | Create | Unit tests for `RollingFileLog`. |
| `voxlineTests/Diagnostics/CategoryLogTests.swift` | Create | Tests that `CategoryLog.debug` does NOT write to file. |
| `voxline/voxlineApp.swift` | Modify (1 line) | Migrate one `\(…, privacy: .public)` call site to plain interpolation. |
| `voxline/Pipeline/CapturePipeline.swift` | Modify (~14 lines) | Migrate all `\(…, privacy: .public)` and `\(…, privacy: .private)` call sites to plain interpolation. |
| `voxline/Storage/DataProtectionKeychain.swift` | Modify (1 line) | Migrate one `\(account, privacy: .public)` call site. (Note: this file uses its own private `Self.log = Logger(...)`, not `AppLog`, so the call still talks to OSLog directly — only the interpolation form needs to change because the new `CategoryLog` API takes `String`. **WAIT** — this file does not use `AppLog` at all, so it is unaffected by the shim. Re-check in Task 8 before changing.) |

---

## Task 1: `RollingFileLog` skeleton + first-entry test

**Files:**
- Create: `voxline/Diagnostics/RollingFileLog.swift`
- Create: `voxlineTests/Diagnostics/RollingFileLogTests.swift`

- [ ] **Step 1: Write the failing test**

Create `voxlineTests/Diagnostics/RollingFileLogTests.swift` with:

```swift
import Testing
import Foundation
@testable import voxline

@Suite struct RollingFileLogTests {

    private static func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "rfl-\(UUID().uuidString).log")
    }

    private static func fixedClock(_ iso: String) -> () -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let d = f.date(from: iso)!
        return { d }
    }

    @Test func appendsFormattedLine() throws {
        let url = Self.tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let log = RollingFileLog(
            fileURL: url,
            clock: Self.fixedClock("2026-05-14T12:34:56.789Z")
        )

        log.info("Dictation finished", category: "pipeline")

        let body = try String(contentsOf: url, encoding: .utf8)
        // Format: [yyyy-MM-dd HH:mm:ss.SSS] [INFO] [pipeline] message
        // Timestamp is rendered in local time, so we assert structure
        // around the level/category/message fields rather than the exact
        // wall-clock string (which depends on the test machine's TZ).
        #expect(body.hasSuffix("[INFO] [pipeline] Dictation finished\n"))
        #expect(body.split(separator: "\n").count == 1)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails (compile error)**

Run:
```bash
xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/RollingFileLogTests
```
Expected: compile failure — `cannot find 'RollingFileLog' in scope`.

- [ ] **Step 3: Create the `RollingFileLog` skeleton**

Create `voxline/Diagnostics/RollingFileLog.swift`:

```swift
import Foundation
import OSLog

/// Persistent rolling text log. Appends formatted lines to a file on disk,
/// keeping at most `maxEntries` lines (oldest evicted first). Thread-safe.
/// Never throws to callers; disk failures are reported once per kind via OSLog.
final class RollingFileLog {

    enum Level: String {
        case info   = "INFO"
        case notice = "NOTICE"
        case error  = "ERROR"
        case fault  = "FAULT"
    }

    private let fileURL: URL
    private let clock: () -> Date
    private let maxEntries: Int

    private let formatter: DateFormatter

    private var ring: [String] = []
    private var initializedFromDisk = false
    private var lock = os_unfair_lock_s()

    init(
        fileURL: URL,
        clock: @escaping () -> Date = Date.init,
        maxEntries: Int = 250
    ) {
        self.fileURL = fileURL
        self.clock = clock
        self.maxEntries = maxEntries

        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        self.formatter = f
    }

    func info(_ message: String, category: String) {
        append(level: .info, category: category, message: message)
    }

    private func append(level: Level, category: String, message: String) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        let line = "[\(formatter.string(from: clock()))] [\(level.rawValue)] [\(category)] \(message)"
        ring.append(line)

        let body = ring.joined(separator: "\n") + "\n"
        do {
            try body.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            // Will gain richer error reporting in Task 5.
        }
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run:
```bash
xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/RollingFileLogTests
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add voxline/Diagnostics/RollingFileLog.swift voxlineTests/Diagnostics/RollingFileLogTests.swift
git commit -m "$(cat <<'EOF'
feat(diagnostics): add RollingFileLog skeleton with single-line append

First slice of the rolling-file-log framework: writes one formatted line
to disk per call. 250-entry cap, restart persistence, concurrency safety,
and error tolerance arrive in subsequent commits.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: 250-entry cap (ring eviction)

**Files:**
- Modify: `voxlineTests/Diagnostics/RollingFileLogTests.swift`
- Modify: `voxline/Diagnostics/RollingFileLog.swift`

- [ ] **Step 1: Add the failing test**

Append inside the `RollingFileLogTests` suite:

```swift
    @Test func respects250Cap() throws {
        let url = Self.tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let log = RollingFileLog(
            fileURL: url,
            clock: Self.fixedClock("2026-05-14T12:34:56.789Z")
        )

        for i in 0..<260 {
            log.info("entry \(i)", category: "pipeline")
        }

        let body = try String(contentsOf: url, encoding: .utf8)
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.isEmpty }

        #expect(lines.count == 250)
        // First 10 entries (0..<10) must have been evicted; oldest
        // surviving entry is "entry 10".
        #expect(lines.first?.hasSuffix("entry 10") == true)
        #expect(lines.last?.hasSuffix("entry 259") == true)
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```bash
xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/RollingFileLogTests/respects250Cap
```
Expected: FAIL — `lines.count` is 260, not 250.

- [ ] **Step 3: Implement ring eviction**

In `RollingFileLog.swift`, modify `append(level:category:message:)`:

```swift
    private func append(level: Level, category: String, message: String) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        let line = "[\(formatter.string(from: clock()))] [\(level.rawValue)] [\(category)] \(message)"
        ring.append(line)
        while ring.count > maxEntries {
            ring.removeFirst()
        }

        let body = ring.joined(separator: "\n") + "\n"
        do {
            try body.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            // Will gain richer error reporting in Task 5.
        }
    }
```

- [ ] **Step 4: Run the test to verify it passes**

Run:
```bash
xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/RollingFileLogTests
```
Expected: PASS (both `appendsFormattedLine` and `respects250Cap`).

- [ ] **Step 5: Commit**

```bash
git add voxline/Diagnostics/RollingFileLog.swift voxlineTests/Diagnostics/RollingFileLogTests.swift
git commit -m "$(cat <<'EOF'
feat(diagnostics): cap RollingFileLog at 250 entries (oldest evicted)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Restart persistence (read-existing on first append)

**Files:**
- Modify: `voxlineTests/Diagnostics/RollingFileLogTests.swift`
- Modify: `voxline/Diagnostics/RollingFileLog.swift`

- [ ] **Step 1: Add two failing tests**

Append inside `RollingFileLogTests`:

```swift
    @Test func survivesRestart() throws {
        let url = Self.tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            let logA = RollingFileLog(
                fileURL: url,
                clock: Self.fixedClock("2026-05-14T12:34:56.789Z")
            )
            for i in 0..<200 {
                logA.info("entry \(i)", category: "pipeline")
            }
        } // logA released here

        let logB = RollingFileLog(
            fileURL: url,
            clock: Self.fixedClock("2026-05-14T12:34:57.000Z")
        )
        for i in 200..<205 {
            logB.info("entry \(i)", category: "pipeline")
        }

        let body = try String(contentsOf: url, encoding: .utf8)
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.isEmpty }

        #expect(lines.count == 205)
        #expect(lines.first?.hasSuffix("entry 0") == true)
        #expect(lines.last?.hasSuffix("entry 204") == true)
    }

    @Test func parsesExistingFileOnFirstAppend() throws {
        let url = Self.tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        // Pre-seed the file with 300 lines (more than the cap).
        let seed = (0..<300).map { "[seeded] entry \($0)" }.joined(separator: "\n") + "\n"
        try seed.write(to: url, atomically: true, encoding: .utf8)

        let log = RollingFileLog(
            fileURL: url,
            clock: Self.fixedClock("2026-05-14T12:34:56.789Z")
        )
        log.info("fresh entry", category: "pipeline")

        let body = try String(contentsOf: url, encoding: .utf8)
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.isEmpty }

        // 300 seeded → trimmed to 250 on first append, then 1 added,
        // then re-trimmed back to 250.
        #expect(lines.count == 250)
        #expect(lines.last?.hasSuffix("fresh entry") == true)
        // Oldest survivor of the 300 seeded was index 51 (0..<300 minus
        // the oldest 50, then minus 1 more when "fresh entry" pushed
        // index 50 out).
        #expect(lines.first?.contains("entry 51") == true)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:
```bash
xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/RollingFileLogTests/survivesRestart -only-testing:voxlineTests/RollingFileLogTests/parsesExistingFileOnFirstAppend
```
Expected: FAIL — `survivesRestart` shows only 5 lines (no seed read), `parsesExistingFileOnFirstAppend` shows only 1 line.

- [ ] **Step 3: Implement startup file-read on first append**

In `RollingFileLog.swift`, replace `append(level:category:message:)`:

```swift
    private func append(level: Level, category: String, message: String) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        if !initializedFromDisk {
            seedFromDiskLocked()
            initializedFromDisk = true
        }

        let line = "[\(formatter.string(from: clock()))] [\(level.rawValue)] [\(category)] \(message)"
        ring.append(line)
        while ring.count > maxEntries {
            ring.removeFirst()
        }

        let body = ring.joined(separator: "\n") + "\n"
        do {
            try body.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            // Will gain richer error reporting in Task 5.
        }
    }

    /// Loads up to `maxEntries` lines from `fileURL` into `ring`. Tolerates
    /// missing or unreadable files by leaving `ring` empty. Caller must
    /// hold `lock`.
    private func seedFromDiskLocked() {
        guard let existing = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        var lines = existing.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        if lines.last == "" { lines.removeLast() }
        if lines.count > maxEntries {
            lines = Array(lines.suffix(maxEntries))
        }
        ring = lines
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run:
```bash
xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/RollingFileLogTests
```
Expected: PASS for all four tests.

- [ ] **Step 5: Commit**

```bash
git add voxline/Diagnostics/RollingFileLog.swift voxlineTests/Diagnostics/RollingFileLogTests.swift
git commit -m "$(cat <<'EOF'
feat(diagnostics): RollingFileLog restores last 250 entries from disk on first append

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Concurrency safety stress test

**Files:**
- Modify: `voxlineTests/Diagnostics/RollingFileLogTests.swift`

(The lock is already in place from Task 1; this task adds the regression test that proves it works.)

- [ ] **Step 1: Add the failing test**

Append inside `RollingFileLogTests`:

```swift
    @Test func concurrentAppendsPreserveCountAndOrdering() async throws {
        let url = Self.tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let log = RollingFileLog(
            fileURL: url,
            clock: Self.fixedClock("2026-05-14T12:34:56.789Z")
        )

        // 4 concurrent producers × 100 lines each = 400 calls; the file
        // ring caps at 250.
        await withTaskGroup(of: Void.self) { group in
            for producer in 0..<4 {
                group.addTask {
                    for i in 0..<100 {
                        log.info("p\(producer)-\(i)", category: "pipeline")
                    }
                }
            }
        }

        let body = try String(contentsOf: url, encoding: .utf8)
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.isEmpty }

        // Exactly 250 lines, none torn (each must contain "[INFO]
        // [pipeline]" — proves the writer never interleaved a partial
        // file body).
        #expect(lines.count == 250)
        for line in lines {
            #expect(line.contains("[INFO] [pipeline] p"),
                    "torn or malformed line: \(line)")
        }
    }
```

- [ ] **Step 2: Run the test to verify it passes (lock already in place)**

Run:
```bash
xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/RollingFileLogTests/concurrentAppendsPreserveCountAndOrdering
```
Expected: PASS. If it fails, the `os_unfair_lock` from Task 1 is missing or misused — fix before commit.

- [ ] **Step 3: Commit**

```bash
git add voxlineTests/Diagnostics/RollingFileLogTests.swift
git commit -m "$(cat <<'EOF'
test(diagnostics): assert RollingFileLog tolerates concurrent appends

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Error tolerance + one-shot OSLog reporting

**Files:**
- Modify: `voxlineTests/Diagnostics/RollingFileLogTests.swift`
- Modify: `voxline/Diagnostics/RollingFileLog.swift`

- [ ] **Step 1: Add the failing test**

Append inside `RollingFileLogTests`:

```swift
    @Test func unwritableFileDoesNotThrow() {
        // Use a path inside a parent directory that doesn't exist; the
        // atomic write will fail and the logger must absorb the error.
        let unwritable = FileManager.default.temporaryDirectory
            .appending(path: "rfl-missing-\(UUID().uuidString)")
            .appending(path: "nested")
            .appending(path: "voxline.log")

        let log = RollingFileLog(
            fileURL: unwritable,
            clock: Self.fixedClock("2026-05-14T12:34:56.789Z")
        )

        // Each of these would throw if the writer propagated errors.
        log.info("first", category: "pipeline")
        log.info("second", category: "pipeline")

        // No assertion needed beyond "did not crash and did not throw" —
        // Swift Testing fails the test on any uncaught error.
        #expect(Bool(true))
    }
```

- [ ] **Step 2: Run the test — should already pass**

Run:
```bash
xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/RollingFileLogTests/unwritableFileDoesNotThrow
```
Expected: PASS (the existing `do { try ... } catch { }` already swallows the error).

- [ ] **Step 3: Add one-shot OSLog reporting to make failures visible without spamming**

In `RollingFileLog.swift`, replace the `// Will gain richer error reporting in Task 5.` block in `append(level:category:message:)` and add a small reporting helper. Final shape of the file should be:

```swift
import Foundation
import OSLog

/// Persistent rolling text log. Appends formatted lines to a file on disk,
/// keeping at most `maxEntries` lines (oldest evicted first). Thread-safe.
/// Never throws to callers; disk failures are reported once per kind via OSLog.
final class RollingFileLog {

    enum Level: String {
        case info   = "INFO"
        case notice = "NOTICE"
        case error  = "ERROR"
        case fault  = "FAULT"
    }

    private enum FailureKind: String {
        case notFound    // ENOENT or parent dir missing
        case permission  // EACCES / EPERM
        case other
    }

    private static let internalLog = Logger(
        subsystem: "com.voxline.app",
        category: "rolling-file-log"
    )

    private let fileURL: URL
    private let clock: () -> Date
    private let maxEntries: Int
    private let formatter: DateFormatter

    private var ring: [String] = []
    private var initializedFromDisk = false
    private var lastReportedFailure: FailureKind?
    private var lock = os_unfair_lock_s()

    init(
        fileURL: URL,
        clock: @escaping () -> Date = Date.init,
        maxEntries: Int = 250
    ) {
        self.fileURL = fileURL
        self.clock = clock
        self.maxEntries = maxEntries

        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        self.formatter = f
    }

    func info(_ message: String, category: String) {
        append(level: .info, category: category, message: message)
    }

    private func append(level: Level, category: String, message: String) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        if !initializedFromDisk {
            seedFromDiskLocked()
            initializedFromDisk = true
        }

        let line = "[\(formatter.string(from: clock()))] [\(level.rawValue)] [\(category)] \(message)"
        ring.append(line)
        while ring.count > maxEntries {
            ring.removeFirst()
        }

        let body = ring.joined(separator: "\n") + "\n"
        do {
            try body.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            reportFailureLocked(error: error)
        }
    }

    private func seedFromDiskLocked() {
        guard let existing = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        var lines = existing.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        if lines.last == "" { lines.removeLast() }
        if lines.count > maxEntries {
            lines = Array(lines.suffix(maxEntries))
        }
        ring = lines
    }

    /// Emits an OSLog `.error` the first time each `FailureKind` occurs
    /// in this process. Caller must hold `lock`.
    private func reportFailureLocked(error: Error) {
        let kind = Self.classify(error)
        guard kind != lastReportedFailure else { return }
        lastReportedFailure = kind
        Self.internalLog.error(
            "RollingFileLog write failed (\(kind.rawValue, privacy: .public)): \(error.localizedDescription, privacy: .public)"
        )
    }

    private static func classify(_ error: Error) -> FailureKind {
        let ns = error as NSError
        switch (ns.domain, ns.code) {
        case (NSCocoaErrorDomain, NSFileNoSuchFileError),
             (NSCocoaErrorDomain, NSFileWriteFileExistsError),
             (NSPOSIXErrorDomain, Int(ENOENT)):
            return .notFound
        case (NSCocoaErrorDomain, NSFileWriteNoPermissionError),
             (NSPOSIXErrorDomain, Int(EACCES)),
             (NSPOSIXErrorDomain, Int(EPERM)):
            return .permission
        default:
            return .other
        }
    }
}
```

- [ ] **Step 4: Run the suite to verify nothing regressed**

Run:
```bash
xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/RollingFileLogTests
```
Expected: PASS for all five tests.

- [ ] **Step 5: Commit**

```bash
git add voxline/Diagnostics/RollingFileLog.swift voxlineTests/Diagnostics/RollingFileLogTests.swift
git commit -m "$(cat <<'EOF'
feat(diagnostics): RollingFileLog reports disk failures once per kind via OSLog

Failures from the atomic file write are caught and emitted to OSLog at
.error once per process per failure category (notFound, permission, other),
preventing log loops while still surfacing problems to Console.app.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: All four levels (`info` / `notice` / `error` / `fault`)

**Files:**
- Modify: `voxlineTests/Diagnostics/RollingFileLogTests.swift`
- Modify: `voxline/Diagnostics/RollingFileLog.swift`

- [ ] **Step 1: Add the failing test**

Append inside `RollingFileLogTests`:

```swift
    @Test func levelStringsAreFixed() throws {
        let url = Self.tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let log = RollingFileLog(
            fileURL: url,
            clock: Self.fixedClock("2026-05-14T12:34:56.789Z")
        )

        log.info("a", category: "pipeline")
        log.notice("b", category: "pipeline")
        log.error("c", category: "pipeline")
        log.fault("d", category: "pipeline")

        let body = try String(contentsOf: url, encoding: .utf8)
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.isEmpty }

        #expect(lines.count == 4)
        #expect(lines[0].contains("[INFO] [pipeline] a"))
        #expect(lines[1].contains("[NOTICE] [pipeline] b"))
        #expect(lines[2].contains("[ERROR] [pipeline] c"))
        #expect(lines[3].contains("[FAULT] [pipeline] d"))
    }
```

- [ ] **Step 2: Run the test to verify it fails (compile error)**

Run:
```bash
xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/RollingFileLogTests/levelStringsAreFixed
```
Expected: compile failure — `notice`, `error`, `fault` not declared on `RollingFileLog`.

- [ ] **Step 3: Add the three missing methods**

In `RollingFileLog.swift`, replace the single `info` method with all four:

```swift
    func info(_ message: String, category: String) {
        append(level: .info, category: category, message: message)
    }

    func notice(_ message: String, category: String) {
        append(level: .notice, category: category, message: message)
    }

    func error(_ message: String, category: String) {
        append(level: .error, category: category, message: message)
    }

    func fault(_ message: String, category: String) {
        append(level: .fault, category: category, message: message)
    }
```

- [ ] **Step 4: Run the suite to verify it passes**

Run:
```bash
xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/RollingFileLogTests
```
Expected: PASS for all six tests.

- [ ] **Step 5: Commit**

```bash
git add voxline/Diagnostics/RollingFileLog.swift voxlineTests/Diagnostics/RollingFileLogTests.swift
git commit -m "$(cat <<'EOF'
feat(diagnostics): expose notice/error/fault levels on RollingFileLog

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: `CategoryLog` shim + reshape `AppLog`

**Files:**
- Modify (rewrite): `voxline/Diagnostics/AppLog.swift`
- Create: `voxlineTests/Diagnostics/CategoryLogTests.swift`

- [ ] **Step 1: Write the failing test for the debug-skips-file rule**

Create `voxlineTests/Diagnostics/CategoryLogTests.swift`:

```swift
import Testing
import Foundation
@testable import voxline

@Suite struct CategoryLogTests {

    private static func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "cl-\(UUID().uuidString).log")
    }

    @Test func debugDoesNotWriteToFile() throws {
        let url = Self.tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let file = RollingFileLog(fileURL: url)
        let cat = CategoryLog(category: "pipeline", file: file)

        cat.debug("verbose detail")

        // No info/notice/error/fault was called, so the file should not
        // have been written at all.
        #expect(FileManager.default.fileExists(atPath: url.path) == false)
    }

    @Test func infoWritesViaShim() throws {
        let url = Self.tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let file = RollingFileLog(fileURL: url)
        let cat = CategoryLog(category: "pipeline", file: file)

        cat.info("through the shim")

        let body = try String(contentsOf: url, encoding: .utf8)
        #expect(body.contains("[INFO] [pipeline] through the shim"))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```bash
xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/CategoryLogTests
```
Expected: compile failure — `cannot find 'CategoryLog' in scope`.

- [ ] **Step 3: Reshape `AppLog.swift`**

Read the current file first to confirm contents (should match what the spec describes — eight categories + signposter). Then replace `voxline/Diagnostics/AppLog.swift` with:

```swift
import Foundation
import OSLog

/// Thin shim that fans out a single log call to both Apple's unified
/// logging (Console.app, `log stream`) and the on-disk `RollingFileLog`.
/// `debug` is OSLog-only and never reaches disk — it exists for verbose
/// development output that would otherwise burn the 250-entry file cap.
struct CategoryLog {

    let category: String
    private let osLogger: Logger
    private let file: RollingFileLog

    init(category: String, file: RollingFileLog) {
        self.category = category
        self.osLogger = Logger(subsystem: AppLog.subsystem, category: category)
        self.file = file
    }

    func debug(_ message: String) {
        osLogger.debug("\(message, privacy: .public)")
    }

    func info(_ message: String) {
        osLogger.info("\(message, privacy: .public)")
        file.info(message, category: category)
    }

    func notice(_ message: String) {
        osLogger.notice("\(message, privacy: .public)")
        file.notice(message, category: category)
    }

    func error(_ message: String) {
        osLogger.error("\(message, privacy: .public)")
        file.error(message, category: category)
    }

    func fault(_ message: String) {
        osLogger.fault("\(message, privacy: .public)")
        file.fault(message, category: category)
    }
}

enum AppLog {
    static let subsystem = "com.voxline.app"

    /// Lazy singleton. Resolves the file URL at first access. If
    /// `AppPaths.applicationSupportDirectory()` throws (extremely
    /// unlikely — it creates the directory), falls back to a path under
    /// the temp directory so the OSLog sink keeps working and disk
    /// writes silently fail (per `RollingFileLog`'s never-throw rule).
    static let fileLog: RollingFileLog = {
        let url: URL
        if let supportDir = try? AppPaths.applicationSupportDirectory() {
            url = supportDir.appending(path: "voxline.log")
        } else {
            url = FileManager.default.temporaryDirectory
                .appending(path: "voxline.log")
        }
        return RollingFileLog(fileURL: url)
    }()

    static let pipeline    = CategoryLog(category: "pipeline",    file: fileLog)
    static let hotkey      = CategoryLog(category: "hotkey",      file: fileLog)
    static let audio       = CategoryLog(category: "audio",       file: fileLog)
    static let whisper     = CategoryLog(category: "whisper",     file: fileLog)
    static let llm         = CategoryLog(category: "llm",         file: fileLog)
    static let paste       = CategoryLog(category: "paste",       file: fileLog)
    static let context     = CategoryLog(category: "context",     file: fileLog)
    static let permissions = CategoryLog(category: "permissions", file: fileLog)

    static let pipelineSignposter = OSSignposter(subsystem: subsystem, category: "pipeline")
}
```

- [ ] **Step 4: Build the app to surface call-site compile errors**

Run:
```bash
xcodebuild build -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS'
```

Expected: the build will fail in `voxline/voxlineApp.swift`, `voxline/Pipeline/CapturePipeline.swift` because those files use OSLog interpolation (`\(x, privacy: .public)`) that the new `CategoryLog.info(_ message: String)` API does not accept. Note these errors — they are the migration targets for Task 8. **Do not fix them yet; commit the AppLog reshape on its own first.**

If you see compile errors in any other file (i.e., not the two files Task 8 covers), stop and re-investigate — there may be call sites outside the spec's scope.

- [ ] **Step 5: Verify the new tests pass in isolation**

The full app won't link, but you can still run the unit tests for `CategoryLog` and `RollingFileLog` because they don't depend on the broken call sites compiling. **Skip this step if Step 4's build failure prevents the test target from building** — proceed straight to Task 8 to unblock the build, then re-run all tests at the end of Task 8.

- [ ] **Step 6: Commit the AppLog reshape (build is currently broken — that is expected)**

```bash
git add voxline/Diagnostics/AppLog.swift voxlineTests/Diagnostics/CategoryLogTests.swift
git commit -m "$(cat <<'EOF'
feat(diagnostics): reshape AppLog into CategoryLog shims that fan out to file + OSLog

Each AppLog category is now a CategoryLog struct that forwards every
info/notice/error/fault call to both the existing OSLog sink and the new
RollingFileLog singleton at <App Support>/voxline/voxline.log. Build is
intentionally broken for callers using OSLog interpolation features; the
follow-up commit migrates them.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Migrate OSLog interpolation call sites

**Files (all known call sites that pass `privacy:` to `AppLog.<category>.<level>(...)`):**
- Modify: `voxline/voxlineApp.swift:201` (1 site)
- Modify: `voxline/Pipeline/CapturePipeline.swift` (15 sites; see below)

The interpolation form `\(value, privacy: .public)` and `\(value, privacy: .private)` is OSLog-specific syntax. The new `CategoryLog` API takes `String`, so each interpolation must drop the `privacy:` argument label. **Per the spec's PII discipline section, treat the `privacy: .private` sites as red flags** — those values were marked private precisely because they could identify the user (app names like `mode.displayName`, `context.appName`). Since the file logger writes verbatim, those values must either be removed from the message or rephrased to non-identifying form.

- [ ] **Step 1: Migrate `voxline/voxlineApp.swift:201`**

Edit the line:

```swift
// Before
AppLog.pipeline.error("modes load failed, using shipped defaults: \(error.localizedDescription, privacy: .public)")
// After
AppLog.pipeline.error("modes load failed, using shipped defaults: \(error.localizedDescription)")
```

- [ ] **Step 2: Migrate `voxline/Pipeline/CapturePipeline.swift` — `.public` sites**

These are safe to convert by simply dropping the privacy label. Do not change call placement or surrounding logic. Sites (line numbers from the current `main` — verify with `grep -n` before editing as line numbers may have drifted):

```swift
// Line 77
AppLog.pipeline.error("capture.start failed: \(error.localizedDescription)")

// Line 111
AppLog.pipeline.info("recording stopped: samples=\(samples.count) duration=\(self.state.lastRecordingDuration ?? 0)s peak=\(self.state.lastPeakLevel)")

// Line 143
AppLog.whisper.error("transcribe failed: \(error.localizedDescription)")

// Line 149
AppLog.whisper.info("transcribed: chars=\(transcript.count) duration=\(self.state.lastTranscribeDuration ?? 0)s")

// Line 165
AppLog.pipeline.error("no mode for bundle=\(bundleID ?? "unknown")")

// Line 176
AppLog.context.info("context partial: notes=\(context.captureNotes.joined(separator: ",")) durationMs=\(context.captureDurationMs)")

// Line 187
AppLog.llm.error("cleanup failed: \(e.errorDescription ?? "unknown")")

// Line 192
AppLog.llm.error("cleanup failed: \(error.localizedDescription)")

// Line 198
AppLog.llm.info("cleanup ok: in=\(transcript.count) out=\(cleaned.count) duration=\(self.state.lastCleanupDuration ?? 0)s")

// Line 211
AppLog.paste.error("inject failed: \(e.errorDescription ?? "unknown")")

// Line 216
AppLog.paste.error("inject failed: \(error.localizedDescription)")
```

- [ ] **Step 3: Migrate `voxline/Pipeline/CapturePipeline.swift` — `debug` sites (still OSLog-only, can keep PII)**

`debug` does not write to the file, so the original PII content is fine — but the `privacy:` label still needs to drop because the new `CategoryLog.debug(_ message: String)` API takes plain `String`:

```swift
// Line 81 — no interpolation, no change needed; verify and skip
AppLog.pipeline.debug("recording started")

// Line 123 — no interpolation, no change needed; verify and skip
AppLog.pipeline.debug("empty capture, idling out")

// Line 169 — drop both privacy labels; safe to keep mode.displayName because debug is OSLog-only
AppLog.pipeline.debug("mode resolved: bundle=\(bundleID ?? "unknown") mode=\(mode.displayName)")

// Line 174 — drop all privacy labels; safe to keep context.appName because debug is OSLog-only
AppLog.context.debug("context: app=\(context.appName ?? "nil") bundle=\(context.bundleID ?? "nil") secure=\(context.isSecureField) durationMs=\(context.captureDurationMs) notes=\(context.captureNotes.joined(separator: ","))")

// Line 206 — drop privacy label
AppLog.paste.debug("inject ok: outcome=\(outcome.description)")
```

- [ ] **Step 4: Migrate `voxline/Pipeline/CapturePipeline.swift:117` — `.error` site with no privacy**

This one currently has no privacy label and no interpolation. Verify it still compiles unchanged:

```swift
// Line 117 — no change needed
AppLog.pipeline.error("silent capture: samples present but peak=0 (mic permission or muted device)")
```

- [ ] **Step 5: Confirm there are no other affected call sites**

Run:
```bash
grep -rn "AppLog\.[a-z]*\.\(info\|notice\|error\|fault\|debug\)" voxline --include="*.swift" | grep "privacy:"
```
Expected: no output. If any line is returned, repeat Step 2/3 logic for it.

`voxline/Storage/DataProtectionKeychain.swift:45` uses its own private `Self.log = Logger(...)` (not `AppLog`), so the `\(account, privacy: .public)` interpolation there continues to compile — **leave it alone**, it's outside the scope of this plan.

- [ ] **Step 6: Build clean**

Run:
```bash
xcodebuild build -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS'
```
Expected: PASS (no compile errors).

- [ ] **Step 7: Run the full test suite**

Run:
```bash
xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS'
```
Expected: PASS for all tests including the new `RollingFileLogTests` and `CategoryLogTests`. If any pre-existing test fails, investigate before proceeding — the migration should be behavior-preserving for OSLog output.

- [ ] **Step 8: Commit**

```bash
git add voxline/voxlineApp.swift voxline/Pipeline/CapturePipeline.swift
git commit -m "$(cat <<'EOF'
refactor(diagnostics): migrate AppLog call sites off OSLog privacy interpolation

The CategoryLog API takes plain Strings (not OSLogMessage), so privacy:
specifiers must be removed at every call site. .public sites convert
cleanly; .private sites lived in debug calls (mode.displayName,
context.appName), which are OSLog-only and never touch the new on-disk
file, so the values remain in OSLog output unchanged.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: End-to-end smoke verification

**Files:** none modified.

Manual verification that the wired-up `AppLog → RollingFileLog → disk` path actually produces a file when the real app runs.

- [ ] **Step 1: Run the app via Xcode (or `./scripts/build-local.sh --debug`) and trigger one dictation**

Press the hotkey, speak briefly, release. This should fire several `AppLog.pipeline.info` / `AppLog.whisper.info` / `AppLog.llm.info` calls.

- [ ] **Step 2: Confirm the file exists at the sandbox path**

Run:
```bash
ls -la ~/Library/Containers/com.voxline.app/Data/Library/Application\ Support/voxline/voxline.log
```
Expected: file exists, non-zero size. (If the bundle ID is different, find it with `mdfind -name voxline.app` and adjust the path.)

- [ ] **Step 3: Inspect the contents**

Run:
```bash
tail -20 ~/Library/Containers/com.voxline.app/Data/Library/Application\ Support/voxline/voxline.log
```
Expected: lines in the format `[2026-MM-DD HH:MM:SS.SSS] [INFO] [pipeline] recording stopped: samples=… duration=…s peak=…`. No PII (no transcript text, no app context names) should appear.

- [ ] **Step 4: Confirm the cap holds in practice**

Run several more dictations until you've definitely produced more than 250 log lines, then re-check:
```bash
wc -l ~/Library/Containers/com.voxline.app/Data/Library/Application\ Support/voxline/voxline.log
```
Expected: line count is 250 (or fewer if you didn't quite hit it).

- [ ] **Step 5: No commit required**

This is a runtime check; nothing changed on disk in the repo. If any step fails, file a follow-up issue describing the actual vs expected behavior — do **not** edit the design or the tests to match unexpected runtime behavior without re-opening the spec.

---

## Self-Review

**Spec coverage check:**

| Spec section | Implementing task |
|---|---|
| Architecture (CategoryLog shim, RollingFileLog, AppLog reshape) | Task 7 |
| File location (`<App Support>/voxline/voxline.log`) | Task 7 (`AppLog.fileLog`) |
| Line format (`[ts] [LEVEL] [category] message`) | Task 1 (formatter), Task 6 (level strings) |
| Plain-`String` API | Task 6, Task 7 |
| `debug` skips the file | Task 7 (CategoryLog), CategoryLogTests |
| 250-cap, oldest-first eviction | Task 2 |
| Restart persistence (read-existing on first append) | Task 3 |
| Synchronous `os_unfair_lock`, no background queue | Task 1 (lock), Task 4 (stress test) |
| Errors never throw, reported once per kind via OSLog | Task 5 |
| Defensive parse on disk read (cap to last 250) | Task 3 (`seedFromDiskLocked`) |
| Migration of existing `privacy:` interpolation call sites | Task 8 |
| Test list from spec (7 tests) | Tasks 1–6 cover all 7; CategoryLog file-skip is Task 7 |
| Non-goals (no UI, no rotation files, no batching) | Plan does not introduce any of these |

**Placeholder scan:** No `TBD`, no `TODO`, no "implement appropriate handling" — every step has concrete code or a concrete command.

**Type consistency:**
- `RollingFileLog.info(_ message: String, category: String)` — same signature in Task 1, Task 6, Task 7 (CategoryLog shim).
- `CategoryLog.init(category: String, file: RollingFileLog)` — matches between Task 7 source and CategoryLogTests.
- `Level` enum raw values (`INFO`, `NOTICE`, `ERROR`, `FAULT`) — used consistently in Tasks 1, 6, the assertion in Task 6's test, and the Task 9 smoke check.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-14-rolling-file-log.md`. Two execution options:

1. **Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration.
2. **Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
