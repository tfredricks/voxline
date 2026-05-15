# Rolling File Log — Design

**Date:** 2026-05-14
**Status:** Draft (pending implementation plan)
**Scope:** Add a persistent on-disk log that mirrors `AppLog`'s OSLog output, capped at the last 250 entries.

## Goal

Voxline today logs only to Apple's unified logging (OSLog), which is invisible to users without Console.app or `log show`. This design adds a single rolling text file in the app's sandboxed Application Support directory so that:

- Users (and support) can grab a recent log without running terminal commands.
- The file is bounded in size — exactly the last 250 entries, oldest evicted first.
- The existing Console.app workflow is preserved unchanged.

The framework is the deliverable. Deciding *what* to log at each level is intentionally out of scope and will be a follow-up.

## Architecture

A new component, `RollingFileLog`, owns the on-disk file and an in-memory ring buffer. The existing `AppLog` enum is reshaped so each category exposes a thin `CategoryLog` shim that fans out every call to **both** OSLog and `RollingFileLog`. Call sites do not change.

```
                              ┌─────────────────────────┐
  AppLog.pipeline.info(...) ──▶│ CategoryLog (shim)     │
                              │  - osLogger (Logger)   │──▶ OSLog (Console.app)
                              │  - file (RollingFL)    │──▶ voxline.log (rolling)
                              └─────────────────────────┘
```

### Components

- **`RollingFileLog`** — `final class` in `voxline/Diagnostics/RollingFileLog.swift`. Owns the 250-entry ring buffer and atomic file rewrites. Thread-safe via `os_unfair_lock`. Knows nothing about OSLog.
- **`CategoryLog`** — `struct` in `voxline/Diagnostics/AppLog.swift`. Wraps both an `os.Logger` and the shared `RollingFileLog` instance. Public surface: `info / notice / error / fault / debug`.
- **`AppLog`** (existing, reshaped) — exposes the same eight categories as today (`pipeline, hotkey, audio, whisper, llm, paste, context, permissions`), each now a `CategoryLog` instead of a raw `Logger`. Adds `AppLog.fileLog`, the lazy singleton `RollingFileLog`.

### Boundaries

- `CategoryLog` is the only thing that knows about both sinks.
- `RollingFileLog` has no global state — it takes `(fileURL, clock, maxEntries)` as init params so tests inject a temp dir and a frozen clock.
- Failures in `RollingFileLog` are caught, reported once per failure-kind via OSLog, and swallowed. **The file logger must never throw to the app or crash it.**

## File location

`<AppPaths.applicationSupportDirectory()>/voxline.log`

Sandbox-resolved: `~/Library/Containers/<bundle-id>/Data/Library/Application Support/voxline/voxline.log`

Uses the existing `AppPaths.applicationSupportDirectory()` helper, which already creates the `voxline/` subdir if missing.

## Line format

```
[2026-05-14 12:34:56.789] [INFO] [pipeline] Dictation finished
```

- **Timestamp:** `yyyy-MM-dd HH:mm:ss.SSS`, local time, millisecond precision. Local because humans read this file; if remote-support cases ever need UTC, the OSLog stream still has it.
- **Level:** uppercase fixed token — one of `INFO`, `NOTICE`, `ERROR`, `FAULT`.
- **Category:** lowercase, matches the existing `AppLog` taxonomy verbatim.
- **Message:** caller-supplied `String`, written as-is. **No newline escaping.** A caller that passes `"a\nb"` produces two on-disk lines counting as two ring entries. Convention: don't log multi-line strings.

`debug` level exists on `CategoryLog` for parity with OSLog but is **not** written to the file. Only `info / notice / error / fault` reach disk.

## Call-site API

Plain `String` message. No structured `meta` dict in v1.

```swift
AppLog.pipeline.info("Dictation finished elapsed_ms=\(ms)")
AppLog.llm.error("OpenAI request failed status=\(code)")
AppLog.hotkey.debug("press detected")   // OSLog only, not written to file
```

### PII discipline

Because the message is a plain `String`, anything interpolated into it is written verbatim to disk. **Do not interpolate user data** (transcripts, paste contents, API keys, app context names, file paths inside the user's home, recipient names, etc.) into log messages. Log identifiers, durations, counts, and error codes only.

This is a discipline at the call site. The framework does not enforce it. Code review and a future spec for "what to log" will codify the boundaries.

### Migration impact

Existing call sites of the form `AppLog.<category>.info("…")` continue to compile and run. Call sites that use OSLog interpolation features — `\(value, privacy: .private)`, format specifiers like `%{public}@`, or `OSLogPrivacy` — must be rewritten to plain `String` interpolation. We will `grep` for these during implementation and convert each.

## `RollingFileLog` internals

### State (guarded by `os_unfair_lock`)

```swift
private var ring: Deque<String> = []   // each element = one fully-formatted line
private let maxEntries = 250
private var initializedFromDisk = false
private var lastReportedFailureKind: FailureKind? = nil
```

### Append path

For each call (`info / notice / error / fault`):

1. Acquire lock.
2. If `!initializedFromDisk`, read the file (if present), split on `\n`, drop trailing empties, take last `maxEntries`, seed `ring`. Set the flag. Failures are tolerated — start with empty ring.
3. Format the line: `[ts] [LEVEL] [category] message`.
4. `ring.append(line)`; while `ring.count > maxEntries`, `ring.removeFirst()`.
5. Build body: `ring.joined(separator: "\n") + "\n"`.
6. Write atomically: `try (body as NSString).write(to: fileURL, atomically: true, encoding: String.Encoding.utf8.rawValue)` (or the Swift equivalent that uses temp-file + rename).
7. On error from steps 5–6: if `failureKind != lastReportedFailureKind`, emit one OSLog `.error` describing it, update the field. Never throw.
8. Release lock.

Concurrency model: simple synchronous lock on the caller's thread. At voxline's volumes (a few logs per dictation, not thousands per second) the rewrite is sub-millisecond on modern SSDs. No background queue, no actor, no coalescing in v1.

### Init

```swift
init(
    fileURL: URL,
    clock: @escaping () -> Date = Date.init,
    maxEntries: Int = 250
)
```

The shared instance in `AppLog` uses production defaults: real file URL from `AppPaths`, `Date.init` clock, cap 250.

### Startup behavior (lazy)

The shared `AppLog.fileLog` is lazy. The first log call after launch triggers the disk read in step 2 above. The file therefore persists "the last 250 entries across the app's lifetime," not just the current session — restart preserves history up to the cap.

If `AppPaths.applicationSupportDirectory()` itself throws (extremely unlikely — it creates the dir), we fall back to an in-memory-only logger by passing a `URL` that lives in `FileManager.default.temporaryDirectory`. The OSLog sink still works regardless.

## Error handling rules

1. `RollingFileLog` never throws to callers and never crashes the app.
2. File-write failures are emitted to OSLog **once per session per failure kind** (`.notFound`, `.permission`, `.diskFull`, `.other`) — avoid spam loops.
3. If the file becomes unwritable mid-session, the in-memory ring keeps working. The framework keeps trying writes; future success silently resumes.
4. Disk reads at startup parse defensively: malformed lines are kept verbatim (we don't reformat), and we cap to the last 250 regardless of how many lines were on disk.

## Testing

New file: `voxlineTests/Diagnostics/RollingFileLogTests.swift`.

| Test | Asserts |
|---|---|
| `appendsFormattedLine` | One `info("hello", category: "pipeline")` with a fixed clock produces the expected single-line file body. |
| `respects250Cap` | 260 appends → exactly 250 lines on disk; first 10 evicted in order. |
| `survivesRestart` | Instance A logs 200 lines, is released. Instance B with same URL logs 5 more. File ends with 205 lines, oldest preserved. |
| `parsesExistingFileOnFirstAppend` | Pre-seed file with 300 lines, init, log 1 more. File ends with 250 lines (defensive trim); new line is last. |
| `concurrentAppendsPreserveCountAndOrdering` | 4 threads × 100 logs each. Final file has exactly 250 lines, all parseable (timestamp/level/category extractable); no torn lines. |
| `unwritableFileDoesNotThrow` | Init with a URL inside a read-only parent. Logging does not throw, does not crash. |
| `levelStringsAreFixed` | Each of `info / notice / error / fault` produces the expected uppercase token. |
| `debugDoesNotWriteToFile` | Calling `CategoryLog.debug(...)` leaves the file unchanged. (Lives in a separate `CategoryLogTests.swift` if we add one.) |

Tests use a per-test temp directory (`FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)`) and a fixed `() -> Date` clock. No real `AppPaths` involvement.

## Non-goals for v1

Explicitly out of scope so they don't drift in during implementation:

- No log viewer UI in the Debug window. (File is for users/support to retrieve manually.)
- No rotation to numbered files (`.1`, `.2`, …) or compression.
- No remote upload, Sentry integration, or analytics.
- No per-category level thresholds.
- No async batching / write coalescing.
- No `meta` dict / structured fields.
- No decision on *what* to log at each level — that is a separate spec.

## Open questions / follow-ups

- After implementation, do a pass on existing call sites: any using `\(x, privacy: .private)` need to be converted, and any logging PII need to be either removed, downgraded to `debug` (OSLog-only), or rephrased to non-identifying form.
- Once the framework lands, write a separate "logging conventions" doc describing what each category logs at each level. That doc, not this one, is where the "what to log" decision lives.
