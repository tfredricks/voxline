import CoreGraphics
import Foundation

/// The meeting timer chip's text and placement, kept pure so the panel
/// never asks SwiftUI's greedy `.timer` text style for its width.
enum MeetingTimerLayout {

    /// Reserves room for `H:MM:SS` so the chip never resizes mid-meeting.
    static let widestLabel = "0:00:00"

    static let cornerMargin = CGSize(width: 16, height: 8)

    static func label(elapsed: TimeInterval) -> String {
        let total = Int(max(0, elapsed))
        let hours = total / 3600
        let minutes = total / 60 % 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// Keeps a remembered position but always takes the current size, so an
    /// autosaved frame from an older, narrower chip can't bring its width back.
    static func frame(size: CGSize, saved: CGRect?, visibleFrame: CGRect) -> CGRect {
        guard let saved else {
            return CGRect(
                x: visibleFrame.maxX - size.width - cornerMargin.width,
                y: visibleFrame.maxY - size.height - cornerMargin.height,
                width: size.width,
                height: size.height
            )
        }
        let x = min(max(saved.minX, visibleFrame.minX), visibleFrame.maxX - size.width)
        let y = min(max(saved.minY, visibleFrame.minY), visibleFrame.maxY - size.height)
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }
}
