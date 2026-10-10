import AppKit
import Foundation
import UserNotifications

enum MeetingNotice: Equatable {
    case capWarning
    case notesReady(URL)
    case nothingRecorded
    /// `retryable` is false for a Regenerate Notes failure, which has no
    /// Retry Processing item.
    case failed(String, retryable: Bool)
    case systemAudioUnavailable
    case recordingStopped(String)
    case systemAudioLost
    /// The meeting shortcut was pressed while the last meeting is processing.
    case busy
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

/// Posts meeting notices through Notification Center. Clicking "notes
/// ready" opens the file. Authorization is requested before the first
/// post; a denied or failed post is logged, never raised.
@MainActor
final class UserNotificationMeetingNotifier: NSObject, MeetingNotifying, UNUserNotificationCenterDelegate {

    private let center = UNUserNotificationCenter.current()

    override init() {
        super.init()
        center.delegate = self
    }

    nonisolated static func text(for notice: MeetingNotice) -> (title: String, body: String) {
        switch notice {
        case .capWarning:
            return ("Meeting recording stops in 5 minutes",
                    "Voxline records meetings for up to 60 minutes. Notes are written when it stops.")
        case .notesReady(let url):
            return ("Meeting notes ready", url.deletingPathExtension().lastPathComponent)
        case .nothingRecorded:
            return ("Nothing was recorded", "No speech was found in the meeting recording.")
        case .failed(let message, let retryable):
            let next = retryable
                ? "Choose Retry Processing in the Voxline menu."
                : "Choose Regenerate Notes in the Voxline menu to try again."
            return ("Couldn't finish the meeting notes", "\(message) \(next)")
        case .systemAudioUnavailable:
            return ("Recording your microphone only",
                    "Voxline couldn't capture your Mac's sound output, so remote speakers won't be separated.")
        case .recordingStopped(let reason):
            let sentence = reason.hasSuffix(".") ? reason : reason + "."
            return ("Meeting recording stopped", "\(sentence) Notes will be written for what was recorded.")
        case .systemAudioLost:
            return ("System audio capture stopped", "Recording continues with your microphone only.")
        case .busy:
            return ("Meeting recording didn't start",
                    "Voxline is still processing the last meeting. Try again when its notes are ready.")
        }
    }

    /// Shows the system prompt the first time; afterwards it only reports
    /// the decision already made.
    func requestAuthorization(then completion: (@Sendable () -> Void)? = nil) {
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                AppLog.meetings.error("notification authorization failed: \(error.localizedDescription, privacy: .public)")
            } else if !granted {
                AppLog.meetings.notice("notifications not allowed; meeting notices will not show")
            }
            completion?()
        }
    }

    func post(_ notice: MeetingNotice) {
        let text = Self.text(for: notice)
        let content = UNMutableNotificationContent()
        content.title = text.title
        content.body = text.body
        if case .notesReady(let url) = notice {
            content.userInfo = ["path": url.path]
        }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        let center = center
        requestAuthorization {
            center.add(request) { error in
                if let error {
                    AppLog.meetings.error("posting meeting notification failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let path = response.notification.request.content.userInfo["path"] as? String {
            DispatchQueue.main.async { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

@MainActor
final class AlertMeetingPrompts: MeetingPrompting {

    func confirmConsent() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Recording a meeting"
        alert.informativeText = "Many places require you to tell everyone in the room or on the call that you're recording. Voxline doesn't announce anything into the call."
        alert.addButton(withTitle: "Start Recording")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    func confirmProcessUnfinished(startedAt: Date) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Process unfinished meeting from \(startedAt.formatted(date: .abbreviated, time: .shortened))?"
        alert.informativeText = "Voxline quit before this meeting's notes were written. The audio is still on this Mac."
        alert.addButton(withTitle: "Process")
        alert.addButton(withTitle: "Discard").hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Meeting recording"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
