import CoreGraphics
import Foundation

/// What the recording pill shows. While recording, the recording view wins;
/// otherwise a pending toast wins (even while thinking); otherwise thinking,
/// or an error's Retry offer while it lasts.
enum PillContent: Equatable {
    case hidden
    case recording
    case thinking
    case toast
    case retry
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
    static let retryButtonWidth: CGFloat = 48
    static let retrySpacing: CGFloat = 8
    /// How long an error keeps offering Retry in the pill.
    static let retryDuration: TimeInterval = 8

    static func content(status: AppStatus, hasToast: Bool, retryOffered: Bool = false) -> PillContent {
        switch status {
        case .recording: return .recording
        case .thinking:  return hasToast ? .toast : .thinking
        case .error:     return hasToast ? .toast : (retryOffered ? .retry : .hidden)
        default:         return hasToast ? .toast : .hidden
        }
    }

    /// Whether a status change to `status` starts a Retry offer.
    static func offersRetry(status: AppStatus, hasRetryTranscript: Bool) -> Bool {
        guard case .error = status else { return false }
        return hasRetryTranscript
    }

    /// Whether the pill takes clicks: while it offers Retry, and while a
    /// toast shows an action button.
    static func acceptsClicks(content: PillContent, hasToastAction: Bool) -> Bool {
        content == .retry || (content == .toast && hasToastAction)
    }

    /// Width of a toast's or Retry offer's content: the text, plus the
    /// button and its spacing when there is one.
    static func messageWidth(textWidth: CGFloat, hasButton: Bool) -> CGFloat {
        hasButton ? textWidth + retrySpacing + retryButtonWidth : textWidth
    }

    static func showsText(content: PillContent, hasText: Bool) -> Bool {
        switch content {
        case .recording, .thinking:   return hasText
        case .toast, .retry, .hidden: return false
        }
    }

    /// `message` up to and including the period of its first ". ", or all of it.
    static func firstSentence(_ message: String) -> String {
        guard let end = message.range(of: ". ") else { return message }
        return String(message[..<end.lowerBound]) + "."
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
