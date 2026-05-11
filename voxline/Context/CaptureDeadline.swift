import Foundation

/// Wall-clock deadline tracker used by `DefaultContextCaptureService` to give
/// each AX call a per-step budget without throwing on miss. Callers check
/// `isExpired` before starting work and consult `remainingMilliseconds()` if
/// they need to size an internal cap (e.g., max-nodes for the AX tree walk).
///
/// Backed by `CFAbsoluteTime`, which is wall-clock — not formally monotonic.
/// An NTP step within a single sub-200ms push-to-talk session is implausible,
/// so the wall-clock vs monotonic distinction doesn't matter here in practice.
struct CaptureDeadline: Sendable {

    let totalMilliseconds: Int
    private let startedAt: CFAbsoluteTime

    init(totalMilliseconds: Int) {
        self.totalMilliseconds = totalMilliseconds
        self.startedAt = CFAbsoluteTimeGetCurrent()
    }

    func elapsedMilliseconds() -> Int {
        let dt = CFAbsoluteTimeGetCurrent() - startedAt
        return max(0, Int(dt * 1_000))
    }

    func remainingMilliseconds() -> Int {
        max(0, totalMilliseconds - elapsedMilliseconds())
    }

    var isExpired: Bool { remainingMilliseconds() == 0 }
}
