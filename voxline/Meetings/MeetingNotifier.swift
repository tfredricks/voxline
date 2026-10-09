import AppKit
import Foundation
import UserNotifications

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

/// Posts meeting notices through Notification Center. Clicking "notes
/// ready" opens the file. A denied or failed post is logged, never raised.
@MainActor
final class UserNotificationMeetingNotifier: NSObject, MeetingNotifying, UNUserNotificationCenterDelegate {

    private let center = UNUserNotificationCenter.current()

    override init() {
        super.init()
        center.delegate = self
    }

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                AppLog.meetings.error("notification authorization failed: \(error.localizedDescription, privacy: .public)")
            } else if !granted {
                AppLog.meetings.notice("notifications not allowed; meeting notices will not show")
            }
        }
    }

    func post(_ notice: MeetingNotice) {
        let content = UNMutableNotificationContent()
        switch notice {
        case .capWarning:
            content.title = "Meeting recording stops in 5 minutes"
            content.body = "Voxline records meetings for up to 60 minutes. Notes are written when it stops."
        case .notesReady(let url):
            content.title = "Meeting notes ready"
            content.body = url.deletingPathExtension().lastPathComponent
            content.userInfo = ["path": url.path]
        case .nothingRecorded:
            content.title = "Nothing was recorded"
            content.body = "No speech was found in the meeting recording."
        case .failed(let message):
            content.title = "Couldn't finish the meeting notes"
            content.body = "\(message) Choose Retry Processing in the Voxline menu."
        case .systemAudioUnavailable:
            content.title = "Recording your microphone only"
            content.body = "Voxline couldn't capture your Mac's sound output, so remote speakers won't be separated."
        }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request) { error in
            if let error {
                AppLog.meetings.error("posting meeting notification failed: \(error.localizedDescription, privacy: .public)")
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
        alert.addButton(withTitle: "Discard")
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
