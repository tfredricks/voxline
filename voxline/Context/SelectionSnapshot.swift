import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Reads the current selection by synthesizing a Cmd+C and reading the copied
/// string back off the pasteboard. This is the fallback behind
/// `EditContextReader` when AX can't say what is selected (some Electron and
/// web views). The user's clipboard is snapshotted and restored whenever the
/// copy changed it, and Cmd+C in a secure (password) field is a no-op on
/// macOS, so a selected password is never copied out.
protocol SelectionSnapshotting: Sendable {
    /// The current selection, or nil when nothing is selected (the synthetic
    /// Cmd+C didn't change the pasteboard), the copied string is empty, or the
    /// clipboard couldn't be snapshotted for restore (in which case we refuse
    /// to clobber it).
    func readSelection() async -> String?
}

struct DefaultSelectionSnapshot: SelectionSnapshotting {
    /// Longest wait after posting the synthetic Cmd+C for the frontmost app to
    /// service the copy and publish it to the pasteboard. The read returns as
    /// soon as the copy lands; with nothing selected it never does, and the
    /// whole wait is spent. Too short and a slow app hasn't written the
    /// pasteboard yet, so the read looks like "nothing selected".
    var copyTimeout: Duration = .milliseconds(150)
    var pollInterval: Duration = .milliseconds(10)
    var pasteboardName: NSPasteboard.Name = .general
    var isTrusted: @Sendable () -> Bool = { AXIsProcessTrusted() }
    var postCopy: @Sendable @MainActor () -> Void = { SyntheticKeys.postCopy() }

    func readSelection() async -> String? {
        // Posting the synthetic Cmd+C requires Accessibility. Without it the
        // keystroke silently no-ops (and a command couldn't insert anyway),
        // so bail before touching the clipboard. Also keeps the synthetic copy
        // out of test runs, where the host isn't Accessibility-trusted.
        guard isTrusted() else { return nil }

        // Snapshot the clipboard and post Cmd+C on the main thread. If we can't
        // snapshot, do NOT touch the clipboard — clobbering it with no way to
        // restore is worse than failing to detect a selection.
        let pasteboardName = pasteboardName
        let postCopy = postCopy
        let prepared: (snapshot: PasteboardSnapshot, changeCount: Int)? = await MainActor.run {
            let pasteboard = NSPasteboard(name: pasteboardName)
            guard let snapshot = try? PasteboardSnapshot.capture(from: pasteboard) else {
                return nil
            }
            let changeCountBeforeCopy = pasteboard.changeCount
            postCopy()
            return (snapshot, changeCountBeforeCopy)
        }
        guard let prepared else { return nil }

        // Unstructured, so a cancelled caller still waits: a restore before
        // the app services the copy would leave the selection on the clipboard.
        let deadline = ContinuousClock.now + copyTimeout
        let pollInterval = pollInterval
        return await Task { @MainActor in
            let pasteboard = NSPasteboard(name: pasteboardName)
            var copied: String?
            while true {
                // A real copy bumps the change count. Unchanged means nothing
                // was selected (or the app refused the copy, e.g. a secure
                // field): the stale clipboard is never a fresh selection.
                if pasteboard.changeCount != prepared.changeCount, let string = pasteboard.string(forType: .string) {
                    copied = string.isEmpty ? nil : string
                    break
                }
                guard ContinuousClock.now < deadline else { break }
                try? await Task.sleep(for: pollInterval)
            }
            if pasteboard.changeCount != prepared.changeCount {
                prepared.snapshot.restore(to: pasteboard)
            }
            return copied
        }.value
    }
}
