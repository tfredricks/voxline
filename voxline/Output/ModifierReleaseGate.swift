// voxline/Output/ModifierReleaseGate.swift
import CoreGraphics

/// Holds a synthetic keystroke back until the user lets go of the trigger's
/// modifiers, so they don't merge into it (a held ⌥ turning Cmd+V into ⌥⌘V).
struct ModifierReleaseGate: Sendable {
    var flagsState: @Sendable () -> CGEventFlags = { CGEventSource.flagsState(.combinedSessionState) }
    var forceClear: @Sendable () -> Void = { SyntheticKeys.forceClearModifiers() }
    var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    var timeout: Duration = .seconds(1)
    var pollInterval: Duration = .milliseconds(15)

    /// Returns once no family in `families` is held (generic bits, so it works
    /// over Screen Sharing). After `timeout`, force-clears once and returns.
    /// Elapsed time is the sum of `pollInterval` sleeps, so an injected
    /// `sleep` drives the timeout too.
    func wait(for families: ModifierFamilies) async throws {
        guard !families.isEmpty else { return }
        var waited: Duration = .zero
        while Self.isHeld(families, in: flagsState()) {
            if waited >= timeout {
                forceClear()
                return
            }
            try await sleep(pollInterval)
            waited += pollInterval
        }
    }

    static func isHeld(_ families: ModifierFamilies, in flags: CGEventFlags) -> Bool {
        !ModifierFamilies(flags: flags).isDisjoint(with: families)
    }

    /// True while any family of either chord is held. Reads `chords` and
    /// `flags` on every call, so a Settings change applies to the next paste.
    static func chordsHeld(
        _ chords: @escaping @Sendable () -> ChordSet,
        flags: @escaping @Sendable () -> CGEventFlags = { CGEventSource.flagsState(.combinedSessionState) }
    ) -> @Sendable () -> Bool {
        { isHeld(chords().families, in: flags()) }
    }
}
