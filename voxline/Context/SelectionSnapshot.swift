import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Reads the current selection from the frontmost app for the "transform
/// selection by voice" path, by synthesizing a Cmd+C and reading the copied
/// string back off the pasteboard.
///
/// Why a clipboard round-trip instead of the Accessibility API? voxline runs
/// in the macOS App Sandbox, which lets it POST events (so Cmd+C / Cmd+V
/// work) but blocks it from READING another process's AX element tree —
/// `kAXSelectedTextAttribute` on another app's focused element comes back nil
/// even with Accessibility granted. A synthetic copy is the sandbox-compatible
/// way to capture a cross-app selection. The user's clipboard is snapshotted
/// and always restored, and Cmd+C in a secure (password) field is a no-op on
/// macOS, so a selected password is never copied out.
protocol SelectionSnapshotting: Sendable {
    /// The current selection, or nil when nothing is selected (the synthetic
    /// Cmd+C didn't change the pasteboard), the copied string is empty, or the
    /// clipboard couldn't be snapshotted for restore (in which case we refuse
    /// to clobber it).
    func readSelection() async -> String?
}

struct DefaultSelectionSnapshot: SelectionSnapshotting {
    /// Transform length limit enforced by the caller (`CapturePipeline`),
    /// which refuses to transform selections longer than this rather than
    /// silently truncating them: `performTransform` pastes back over the full
    /// live selection, so a truncated read would desync the read range from
    /// the write range and silently drop the untransformed tail.
    static let selectionMax = 8_000

    /// Time to wait after posting the synthetic Cmd+C for the frontmost app to
    /// service the copy and publish it to the pasteboard before we read it
    /// back. Mirrors the injector's `verificationDelay`; too short and a slow
    /// app hasn't written the pasteboard yet, so the read looks like "nothing
    /// selected".
    var copySettleDelay: Duration = .milliseconds(150)

    func readSelection() async -> String? {
        // Posting the synthetic Cmd+C requires Accessibility. Without it the
        // keystroke silently no-ops (and transform couldn't paste back anyway),
        // so bail before touching the clipboard. Also keeps the synthetic copy
        // out of test runs, where the host isn't Accessibility-trusted.
        guard AXIsProcessTrusted() else { return nil }

        // Snapshot the clipboard and post Cmd+C on the main thread. If we can't
        // snapshot, do NOT touch the clipboard — clobbering it with no way to
        // restore is worse than failing to detect a selection.
        let prepared: (snapshot: PasteboardSnapshot, changeCount: Int)? = await MainActor.run {
            let pasteboard = NSPasteboard.general
            guard let snapshot = try? PasteboardSnapshot.capture(from: pasteboard) else {
                return nil
            }
            let changeCountBeforeCopy = pasteboard.changeCount
            ClipboardInjector.defaultPostKey(ClipboardInjector.kVirtualKeyC, [.maskCommand])
            return (snapshot, changeCountBeforeCopy)
        }
        guard let prepared else { return nil }

        // Let the frontmost app service the copy before reading it back.
        try? await Task.sleep(for: copySettleDelay)

        return await MainActor.run {
            let pasteboard = NSPasteboard.general
            // Always restore the user's clipboard — real copy, empty copy, or
            // cancellation at the sleep above all land here.
            defer { prepared.snapshot.restore(to: pasteboard) }

            // A real copy bumps the change count. If it didn't change, nothing
            // was selected (or the app refused the copy, e.g. a secure field) —
            // treat as no selection so the speech is dictated, not applied as
            // a transform command. The stale clipboard must never be mistaken
            // for a fresh selection.
            guard pasteboard.changeCount != prepared.changeCount else { return nil }
            guard let copied = pasteboard.string(forType: .string), !copied.isEmpty else {
                return nil
            }
            return copied
        }
    }
}
