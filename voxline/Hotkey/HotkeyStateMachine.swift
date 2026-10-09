import Foundation

/// Pure state machine for two hold-to-talk chords. Inputs are events; outputs
/// are effects. No taps, no timers.
final class HotkeyStateMachine {

    enum State: Equatable {
        case idle, armed, blocked
        case recording(CaptureKind)
        case finalizing(CaptureKind)
    }

    enum Input: Equatable {
        case modifiersChanged(Set<HotkeyChord.Modifier>)
        case keyDown
        case shortcutWindowClosed
        case maxDurationElapsed
        case inputLost
        case resync(Set<HotkeyChord.Modifier>)
        case recordingFinished
    }

    enum Output: Equatable {
        case startRecording(CaptureKind)
        case finalizeRecording(CaptureKind)
        case discardRecording(CaptureKind)
        case beginPrewarm
        case cancelPrewarm
    }

    var chords: ChordSet
    private(set) var state: State = .idle
    private var lastHeld: Set<HotkeyChord.Modifier> = []
    private var shortcutWindowOpen = false
    /// A resync during finalizing found keys down: like `blocked`, they can't
    /// start a recording until every modifier is up.
    private var blockedAfterFinalizing = false

    init(chords: ChordSet = .default) {
        self.chords = chords
    }

    @discardableResult
    func handle(_ input: Input) -> [Output] {
        switch (state, input) {
        case (.idle, .modifiersChanged(let h)), (.armed, .modifiersChanged(let h)):
            lastHeld = h
            return evaluate(h)

        case (.armed, .keyDown):
            state = .blocked
            return [.cancelPrewarm]

        case (.blocked, .modifiersChanged(let h)):
            lastHeld = h
            if h.isEmpty { state = .idle }
            return []

        case (.recording(let kind), .modifiersChanged(let h)):
            lastHeld = h
            let chordKeys = chords.chord(for: kind)?.keys ?? []
            if !chordKeys.isSubset(of: h) {
                shortcutWindowOpen = false
                state = .finalizing(kind)
                return [.finalizeRecording(kind)]
            }
            if shortcutWindowOpen, !h.isSubset(of: chordKeys) {
                shortcutWindowOpen = false
                state = .blocked
                return [.discardRecording(kind)]
            }
            return []

        case (.recording(let kind), .keyDown):
            guard shortcutWindowOpen else { return [] }
            shortcutWindowOpen = false
            state = .blocked
            return [.discardRecording(kind)]

        case (.recording, .shortcutWindowClosed):
            shortcutWindowOpen = false
            return []

        case (.recording(let kind), .maxDurationElapsed), (.recording(let kind), .inputLost):
            lastHeld = []
            shortcutWindowOpen = false
            state = .finalizing(kind)
            return [.finalizeRecording(kind)]

        case (.finalizing, .modifiersChanged(let h)):
            lastHeld = h
            if h.isEmpty { blockedAfterFinalizing = false }
            return []

        case (.finalizing, .resync(let h)):
            lastHeld = h
            blockedAfterFinalizing = !h.isEmpty
            return []

        case (.finalizing, .inputLost):
            lastHeld = []
            blockedAfterFinalizing = false
            return []

        case (.finalizing, .recordingFinished):
            if blockedAfterFinalizing {
                blockedAfterFinalizing = false
                state = .blocked
                return []
            }
            return evaluate(lastHeld)

        case (.idle, .inputLost), (.armed, .inputLost), (.blocked, .inputLost):
            let wasArmed = (state == .armed)
            lastHeld = []
            state = .idle
            return wasArmed ? [.cancelPrewarm] : []

        case (.idle, .resync(let h)), (.armed, .resync(let h)), (.blocked, .resync(let h)):
            let wasArmed = (state == .armed)
            lastHeld = h
            state = h.isEmpty ? .idle : .blocked
            return wasArmed ? [.cancelPrewarm] : []

        default:
            return []
        }
    }

    private func evaluate(_ held: Set<HotkeyChord.Modifier>) -> [Output] {
        let previous = state
        if let kind = chords.kind(matching: held) {
            state = .recording(kind)
            shortcutWindowOpen = true
            return [.startRecording(kind)]
        }
        if held.isEmpty {
            state = .idle
            return previous == .armed ? [.cancelPrewarm] : []
        }
        if chords.isStrictSubsetOfAny(held) {
            state = .armed
            return previous == .armed ? [] : [.beginPrewarm]
        }
        state = .blocked
        return previous == .armed ? [.cancelPrewarm] : []
    }
}
