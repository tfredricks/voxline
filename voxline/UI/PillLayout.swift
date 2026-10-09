import CoreGraphics
import Foundation

/// What the recording pill shows. While recording, the recording view wins;
/// otherwise a pending toast wins (even while thinking); otherwise thinking.
enum PillContent: Equatable {
    case hidden
    case recording
    case thinking
    case toast
}

enum PillLayout {
    static let wideWidth: CGFloat = 440
    static let compactWidth: CGFloat = 160
    static let compactHeight: CGFloat = 32
    static let textHeight: CGFloat = 64
    static let bottomMargin: CGFloat = 24
    static let edgeInset: CGFloat = 8
    static let toastMinimumWidth: CGFloat = 120
    static let toastHorizontalPadding: CGFloat = 24

    static func content(status: AppStatus, hasToast: Bool) -> PillContent {
        switch status {
        case .recording: return .recording
        case .thinking:  return hasToast ? .toast : .thinking
        default:         return hasToast ? .toast : .hidden
        }
    }

    static func showsText(content: PillContent, hasText: Bool) -> Bool {
        switch content {
        case .recording, .thinking: return hasText
        case .toast, .hidden:       return false
        }
    }

    static func size(showsText: Bool, toastWidth: CGFloat?) -> CGSize {
        if showsText {
            return CGSize(width: wideWidth, height: textHeight)
        }
        if let toastWidth {
            let width = min(max(toastWidth + toastHorizontalPadding, toastMinimumWidth), wideWidth)
            return CGSize(width: width, height: compactHeight)
        }
        return CGSize(width: compactWidth, height: compactHeight)
    }

    /// Bottom-center of `visibleFrame`, `bottomMargin` above its bottom edge,
    /// kept `edgeInset` from the sides. A frame narrower than the pill pins
    /// the pill's leading edge to the inset.
    static func origin(for size: CGSize, in visibleFrame: CGRect) -> CGPoint {
        let centered = visibleFrame.midX - size.width / 2
        let lowest = visibleFrame.minX + edgeInset
        let highest = visibleFrame.maxX - size.width - edgeInset
        return CGPoint(x: max(lowest, min(centered, highest)), y: visibleFrame.minY + bottomMargin)
    }

    static func elapsedLabel(_ seconds: TimeInterval) -> String {
        let seconds = max(0, seconds)
        if seconds < 60 {
            return String(format: "%.1fs", seconds)
        }
        let whole = Int(seconds)
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    /// Stable text (primary) and volatile text (secondary) whose concatenation
    /// equals `partial.text`; the seam space travels with the volatile side.
    static func transcriptSegments(_ partial: TranscriptPartial) -> (primary: String, secondary: String) {
        let primary = TranscriptPartial.join(partial.stable, "")
        let text = partial.text
        return (primary, String(text.dropFirst(primary.count)))
    }
}
