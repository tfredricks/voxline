import Foundation

/// When the idle audio engine keeps running after a capture, and when it
/// finally stops. A cold engine start costs 160–240 ms before the first
/// sample arrives, which is a dropped first word for anyone who speaks as
/// they press; dictations come in bursts, so the engine stays warm for
/// `keepWarmDuration` after each one. The cost is the system microphone
/// indicator staying lit for that long.
struct CaptureWarmth: Equatable {

    static let keepWarmDuration: Duration = .seconds(90)

    enum Event: Equatable {
        case captureStarted
        case captureStopped
        /// An armed chord was released without recording.
        case prewarmCancelled
        case keepWarmElapsed
        /// The preferred input device changed with no capture running. The
        /// engine must stop to take it: a running engine keeps its device.
        case inputChanged
    }

    enum Action: Equatable {
        case scheduleKeepWarmStop
        case cancelKeepWarmStop
        case stopEngine
    }

    private(set) var keepWarmPending = false

    @discardableResult
    mutating func handle(_ event: Event) -> [Action] {
        switch event {
        case .captureStarted:
            guard keepWarmPending else { return [] }
            keepWarmPending = false
            return [.cancelKeepWarmStop]
        case .captureStopped:
            keepWarmPending = true
            return [.scheduleKeepWarmStop]
        case .prewarmCancelled:
            return keepWarmPending ? [] : [.stopEngine]
        case .keepWarmElapsed:
            keepWarmPending = false
            return [.stopEngine]
        case .inputChanged:
            keepWarmPending = false
            return [.cancelKeepWarmStop, .stopEngine]
        }
    }
}
