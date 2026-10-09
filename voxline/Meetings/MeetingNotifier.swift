import Foundation

enum MeetingNotice: Equatable {
    case capWarning
    case notesReady(URL)
    case nothingRecorded
    case failed(String)
    case systemAudioUnavailable
}

@MainActor
protocol MeetingNotifying: AnyObject {
    func post(_ notice: MeetingNotice)
}

@MainActor
protocol MeetingPrompting: AnyObject {
    /// The one-time recording-consent reminder. False cancels the start.
    func confirmConsent() -> Bool
    /// True processes the unfinished meeting; false discards it.
    func confirmProcessUnfinished(startedAt: Date) -> Bool
    func showError(_ message: String)
}
