// voxline/Output/PasteInjector.swift
import AppKit
import ApplicationServices

/// Pasteboard snapshot capture seam. Production wraps `PasteboardSnapshot.capture`;
/// tests fake it to drive a refused snapshot.
protocol PasteboardSnapshotting: Sendable {
    func capture(from pasteboard: NSPasteboard) throws -> PasteboardSnapshot
}

struct DefaultPasteboardSnapshotter: PasteboardSnapshotting {
    func capture(from pasteboard: NSPasteboard) throws -> PasteboardSnapshot {
        try PasteboardSnapshot.capture(from: pasteboard)
    }
}

/// Pastes through a promised pasteboard item and puts the user's clipboard
/// back once the target has read it (issue 6).
@MainActor
final class PasteInjector {

    /// `pasted` and `focusMoved` mean Cmd+V was posted, so the caller must not
    /// try another strategy. `snapshotRefused` means the board was never
    /// touched. `focusMovedBeforePaste` means focus left the baseline element
    /// before the Cmd+V, and `cancelled` that the calling task was cancelled
    /// before it; in both, nothing was posted and the board was restored.
    enum Outcome: Equatable {
        case pasted(verified: Bool)
        case snapshotRefused(String)
        case focusMovedBeforePaste
        case focusMoved
        case cancelled
    }

    /// The last paste's slot, claimed before its first suspension. It
    /// completes once that paste's restore tail has run (or it was refused),
    /// so the next paste, and tests, can await it.
    private(set) var pendingRestore: Task<Void, Never>?

    private let pasteboard: NSPasteboard
    private let snapshotter: PasteboardSnapshotting
    private let postPaste: @Sendable () -> Void
    private let gate: ModifierReleaseGate
    private let sleep: @Sendable (Duration) async throws -> Void
    private let settleDelay: Duration
    private let verifyInterval: Duration
    private let verifyTimeout: Duration
    private let restoreAfterProvider: Duration
    private let restoreCeiling: Duration

    init(pasteboard: NSPasteboard = .general,
         snapshotter: PasteboardSnapshotting = DefaultPasteboardSnapshotter(),
         postPaste: @escaping @Sendable () -> Void = { SyntheticKeys.postPaste() },
         gate: ModifierReleaseGate = ModifierReleaseGate(),
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         settleDelay: Duration = .milliseconds(50),
         verifyInterval: Duration = .milliseconds(50),
         verifyTimeout: Duration = .milliseconds(300),
         restoreAfterProvider: Duration = .milliseconds(150),
         restoreCeiling: Duration = .milliseconds(1500)) {
        self.pasteboard = pasteboard
        self.snapshotter = snapshotter
        self.postPaste = postPaste
        self.gate = gate
        self.sleep = sleep
        self.settleDelay = settleDelay
        self.verifyInterval = verifyInterval
        self.verifyTimeout = verifyTimeout
        self.restoreAfterProvider = restoreAfterProvider
        self.restoreCeiling = restoreCeiling
    }

    /// Waits for a pending restore, snapshots, writes the promised item, runs
    /// the gate for `trigger`, settles, checks cancellation and focus, posts
    /// Cmd+V, verifies, and schedules the restore tail. `element` is read for verification;
    /// `focused` is re-read to detect a focus shift. When `element` is given
    /// it must be the focused element the caller already checked, and its
    /// ref is the focus baseline. Without one, `focused()` read just before
    /// the promised write is the baseline. A move away from the baseline
    /// during the waits skips the Cmd+V; a move after it is `focusMoved`.
    /// An unreadable focus never counts as a move.
    ///
    /// The tail restores `restoreAfterProvider` after the first provider call
    /// that follows the Cmd+V, or `restoreCeiling` after the Cmd+V, whichever
    /// comes first, and only while the board's change count is still ours.
    /// A provider call before the Cmd+V (an eager clipboard manager) is
    /// ignored; AppKit serves later reads from its cache, so that paste
    /// restores at the ceiling.
    func paste(_ text: String, element: (any AXTextElement)?, trigger: ModifierFamilies,
               focused: @escaping @Sendable () -> AXElementRef?) async -> Outcome {
        let previous = pendingRestore
        let (released, release) = AsyncStream<Never>.makeStream()
        pendingRestore = Task { for await _ in released {} }
        var handedOff = false
        defer { if !handedOff { release.finish() } }
        await previous?.value

        let snapshot: PasteboardSnapshot
        do {
            snapshot = try snapshotter.capture(from: pasteboard)
        } catch let error as PasteboardSnapshot.SnapshotError {
            AppLog.paste.debug("paste skipped: snapshot refused (\(error.reason, privacy: .public))")
            return .snapshotRefused(error.reason)
        } catch {
            AppLog.paste.debug("paste skipped: snapshot failed (\(error.localizedDescription, privacy: .public))")
            return .snapshotRefused(error.localizedDescription)
        }

        let before = element?.string(kAXValueAttribute).value
        let beforeRef = element?.ref ?? focused()

        let provider = PromiseProvider(text: text)
        let ourChangeCount = PasteboardWriter.writePromised(provider: provider, to: pasteboard)

        try? await gate.wait(for: trigger)
        try? await sleep(settleDelay)
        if Task.isCancelled {
            if pasteboard.changeCount == ourChangeCount { snapshot.restore(to: pasteboard) }
            AppLog.paste.debug("paste skipped: cancelled before the Cmd+V")
            return .cancelled
        }
        if let beforeRef, let now = focused(), now != beforeRef {
            if pasteboard.changeCount == ourChangeCount { snapshot.restore(to: pasteboard) }
            AppLog.paste.debug("paste skipped: focus moved before the Cmd+V")
            return .focusMovedBeforePaste
        }
        provider.arm()
        postPaste()
        let pasted = ContinuousClock.now

        restoreTail(snapshot: snapshot, ourChangeCount: ourChangeCount, provider: provider, release: release)
        handedOff = true

        let outcome = await verify(element: element, before: before, beforeRef: beforeRef, focused: focused)
        let elapsed = pasted.duration(to: .now)
        AppLog.paste.debug("paste \(Self.label(outcome), privacy: .public) after \(Int(elapsed / .milliseconds(1)), privacy: .public) ms")
        return outcome
    }

    private func verify(element: (any AXTextElement)?, before: String?, beforeRef: AXElementRef?,
                        focused: @Sendable () -> AXElementRef?) async -> Outcome {
        var waited: Duration = .zero
        while waited < verifyTimeout {
            try? await sleep(verifyInterval)
            waited += verifyInterval
            if let before, let after = element?.string(kAXValueAttribute).value, after != before {
                return .pasted(verified: true)
            }
            if let beforeRef, let now = focused(), now != beforeRef {
                return .focusMoved
            }
        }
        return .pasted(verified: false)
    }

    private enum RestoreTrigger: String {
        case provider = "after the target read it"
        case ceiling = "at the ceiling"
    }

    private func restoreTail(snapshot: PasteboardSnapshot, ourChangeCount: Int, provider: PromiseProvider,
                             release: AsyncStream<Never>.Continuation) {
        let sleep = self.sleep
        let afterProvider = restoreAfterProvider
        let ceiling = restoreCeiling
        let pasteboard = self.pasteboard
        Task { @MainActor in
            defer { release.finish() }
            let trigger = await withTaskGroup(of: RestoreTrigger?.self, returning: RestoreTrigger?.self) { group in
                group.addTask {
                    await provider.firstCallAfterArm()
                    guard !Task.isCancelled else { return nil }
                    do { try await sleep(afterProvider) } catch { return nil }
                    return .provider
                }
                group.addTask {
                    do { try await sleep(ceiling) } catch { return nil }
                    return .ceiling
                }
                for await finished in group {
                    guard let finished else { continue }
                    group.cancelAll()
                    return finished
                }
                return nil
            }
            guard pasteboard.changeCount == ourChangeCount else {
                AppLog.paste.debug("clipboard restore skipped: the clipboard changed after the paste")
                return
            }
            snapshot.restore(to: pasteboard)
            AppLog.paste.debug("clipboard restored \(trigger?.rawValue ?? "after cancellation", privacy: .public)")
        }
    }

    private static func label(_ outcome: Outcome) -> String {
        switch outcome {
        case .pasted(let verified): return verified ? "verified" : "unverified"
        case .snapshotRefused: return "refused"
        case .focusMovedBeforePaste: return "skipped, focus moved"
        case .focusMoved: return "focus moved"
        case .cancelled: return "cancelled"
        }
    }
}

/// Serves the paste text on demand and reports the first request made after
/// `arm()`, the only real signal that the target has pasted.
private final class PromiseProvider: NSObject, NSPasteboardItemDataProvider, @unchecked Sendable {
    private let text: String
    private let lock = NSLock()
    private var armed = false
    private var fired = false
    private var waiters: [UInt64: CheckedContinuation<Void, Never>] = [:]
    private var nextWaiter: UInt64 = 0

    init(text: String) { self.text = text }

    func arm() { lock.withLock { armed = true } }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        item.setString(text, forType: type)
        let resumed: [CheckedContinuation<Void, Never>] = lock.withLock {
            guard armed, !fired else { return [] }
            fired = true
            defer { waiters.removeAll() }
            return Array(waiters.values)
        }
        for continuation in resumed { continuation.resume() }
    }

    func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {}

    /// Returns at the first provider call after `arm()`, or when the calling
    /// task is cancelled.
    func firstCallAfterArm() async {
        let id: UInt64 = lock.withLock {
            nextWaiter += 1
            return nextWaiter
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if fired || Task.isCancelled {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                waiters[id] = continuation
                lock.unlock()
            }
        } onCancel: {
            let waiter = lock.withLock { waiters.removeValue(forKey: id) }
            waiter?.resume()
        }
    }
}
