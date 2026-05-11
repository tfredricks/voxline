import Foundation

struct SupportEnvironment: Equatable {
    let appVersion: String
    let buildNumber: String
    let osVersion: String
    let whisperModel: String
    let micDevice: String?

    var bodyMarkdown: String {
        """
        **Environment**
        - Voxline version: \(appVersion) (\(buildNumber))
        - macOS: \(osVersion)
        - Whisper model: \(whisperModel)
        - Mic device: \(micDevice ?? "(system default)")
        """
    }

    static func current(whisperModel: String, micDevice: String?) -> SupportEnvironment {
        let info = Bundle.main.infoDictionary ?? [:]
        let appVersion = (info["CFBundleShortVersionString"] as? String) ?? "?"
        let buildNumber = (info["CFBundleVersion"] as? String) ?? "?"
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        return SupportEnvironment(
            appVersion: appVersion,
            buildNumber: buildNumber,
            osVersion: osVersion,
            whisperModel: whisperModel,
            micDevice: micDevice
        )
    }
}

enum SupportLinks {
    static let repoURL = URL(string: "https://github.com/tfredricks/voxline")!

    static func bugReportURL(env: SupportEnvironment) -> URL {
        issueURL(template: "bug.yml", body: env.bodyMarkdown)
    }

    static func feedbackURL(env: SupportEnvironment) -> URL {
        issueURL(template: "feedback.yml", body: env.bodyMarkdown)
    }

    private static func issueURL(template: String, body: String) -> URL {
        var components = URLComponents(string: "https://github.com/tfredricks/voxline/issues/new")!
        components.queryItems = [
            URLQueryItem(name: "template", value: template),
            URLQueryItem(name: "body", value: body),
        ]
        return components.url!
    }
}
