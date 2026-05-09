// voxline/Output/ClipboardInjector.swift
import AppKit
import CoreGraphics

/// Polled by ClipboardInjector to gate the synthetic Cmd+V on the user
/// physically releasing the chord. Production impl wraps CGEventSource;
/// tests fake it.
protocol ModifierGate: Sendable {
    /// True iff Left-Ctrl OR Left-Option is currently physically held.
    func chordIsHeld() -> Bool
    /// Synthesize a flagsChanged that clears Left-Ctrl + Left-Option.
    /// Used after the release-timeout elapses.
    func forceClearChord()
}

/// Posts synthetic key events. Wraps CGEvent.post in production; faked in tests.
protocol KeyEventPosting: Sendable {
    func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags)
}

struct CGEventModifierGate: ModifierGate {
    func chordIsHeld() -> Bool {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        // Flag bits for individual sides aren't exposed publicly on macOS;
        // checking the combined Control/Option masks is the documented way.
        // (This is conservative — any Ctrl or any Option held returns true.
        //  In practice voxline's chord IS Left-Ctrl + Left-Option so this is fine.)
        return flags.contains(.maskControl) || flags.contains(.maskAlternate)
    }

    func forceClearChord() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let event = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)
        event?.flags = []   // Clearing all modifier flags — a synthetic "fingers off keyboard"
        event?.type = .flagsChanged
        event?.post(tap: .cghidEventTap)
    }
}

struct CGEventKeyPoster: KeyEventPosting {
    func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags) {
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true)
        down?.flags = flags
        down?.post(tap: .cghidEventTap)
        let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)
        up?.flags = flags
        up?.post(tap: .cghidEventTap)
    }
}

@MainActor
final class ClipboardInjector {

    enum InjectError: Error {
        case clipboardSnapshotFailed(Error)
    }

    /// Virtual key code for "V" on macOS US ANSI layout.
    static let kVirtualKeyV: CGKeyCode = 9

    let pasteboard: NSPasteboard
    let modifierGate: ModifierGate
    let keyPoster: KeyEventPosting
    let chordReleaseTimeout: Duration
    let chordPollInterval: Duration
    let restoreDelay: Duration

    init(
        pasteboard: NSPasteboard = .general,
        modifierGate: ModifierGate = CGEventModifierGate(),
        keyPoster: KeyEventPosting = CGEventKeyPoster(),
        chordReleaseTimeout: Duration = .seconds(1),
        chordPollInterval: Duration = .milliseconds(15),
        restoreDelay: Duration = .milliseconds(300)
    ) {
        self.pasteboard = pasteboard
        self.modifierGate = modifierGate
        self.keyPoster = keyPoster
        self.chordReleaseTimeout = chordReleaseTimeout
        self.chordPollInterval = chordPollInterval
        self.restoreDelay = restoreDelay
    }

    /// Snapshot → write text → wait-for-release → Cmd+V → restore.
    /// Throws `PasteboardSnapshot.SnapshotError.refuseToClobber` if we can't
    /// safely capture the prior pasteboard contents.
    func inject(_ text: String) async throws {
        // 1. Snapshot. Throws on refuse-to-clobber; we propagate.
        let snapshot = try PasteboardSnapshot.capture(from: pasteboard)

        // 2. Write cleaned text.
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // 3. Wait for the user's chord to release before posting Cmd+V.
        await waitForChordRelease()

        // 4. Post Cmd+V with ONLY the Command flag (per spec §4.3 step 4).
        keyPoster.postKey(Self.kVirtualKeyV, flags: [.maskCommand])

        // 5. Restore after a short delay so the target app has time to consume the paste.
        try? await Task.sleep(for: restoreDelay)
        snapshot.restore(to: pasteboard)
    }

    private func waitForChordRelease() async {
        let deadline = ContinuousClock.now.advanced(by: chordReleaseTimeout)
        while modifierGate.chordIsHeld() {
            if ContinuousClock.now >= deadline {
                modifierGate.forceClearChord()
                return
            }
            try? await Task.sleep(for: chordPollInterval)
        }
    }
}
