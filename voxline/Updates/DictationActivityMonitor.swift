import Foundation
import Observation

@Observable
@MainActor
final class DictationActivityMonitor {

    static let deferralWindow: TimeInterval = 120

    private(set) var isActive: Bool = false
    private(set) var lastActivityAt: Date?

    func observe(status: AppStatus, at now: Date = .now) {
        let nowActive: Bool = {
            switch status {
            case .recording, .thinking: return true
            default: return false
            }
        }()

        // Falling edge — dictation just ended. Stamp the moment so the
        // deferral window starts counting from here.
        if isActive && !nowActive {
            lastActivityAt = now
        }
        // Rising edge — also stamp, so a still-in-flight session keeps the
        // window open even if status flips through unrelated states later.
        if !isActive && nowActive {
            lastActivityAt = now
        }
        isActive = nowActive
    }

    func isWithinDeferralWindow(now: Date = .now) -> Bool {
        if isActive { return true }
        guard let last = lastActivityAt else { return false }
        return now.timeIntervalSince(last) < Self.deferralWindow
    }
}
