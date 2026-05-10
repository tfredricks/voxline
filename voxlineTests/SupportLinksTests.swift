import Testing
import Foundation
@testable import voxline

@Suite struct SupportLinksTests {

    @Test func repo_url_is_canonical_https() {
        #expect(SupportLinks.repoURL.absoluteString == "https://github.com/tfredricks/voxline")
    }

    @Test func bug_report_url_uses_bug_template_and_encodes_body() {
        let env = SupportEnvironment(
            appVersion: "1.0",
            buildNumber: "1",
            osVersion: "Version 14.5 (Build 23F79)",
            whisperModel: "large-v3-turbo",
            micDevice: "MacBook Pro Microphone"
        )
        let url = SupportLinks.bugReportURL(env: env)
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            Issue.record("Failed to parse URL components from \(url)")
            return
        }
        #expect(components.host == "github.com")
        #expect(components.path == "/tfredricks/voxline/issues/new")
        let query = components.queryItems ?? []
        #expect(query.contains(URLQueryItem(name: "template", value: "bug.yml")))
        let body = query.first { $0.name == "body" }?.value ?? ""
        #expect(body.contains("voxline version: 1.0 (1)"))
        #expect(body.contains("macOS: Version 14.5 (Build 23F79)"))
        #expect(body.contains("Whisper model: large-v3-turbo"))
        #expect(body.contains("Mic device: MacBook Pro Microphone"))
    }

    @Test func bug_report_url_falls_back_to_system_default_for_missing_mic() {
        let env = SupportEnvironment(
            appVersion: "1.0", buildNumber: "1",
            osVersion: "14.5", whisperModel: "tiny", micDevice: nil
        )
        let url = SupportLinks.bugReportURL(env: env)
        let body = (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .first { $0.name == "body" }?.value ?? ""
        #expect(body.contains("Mic device: (system default)"))
    }

    @Test func feedback_url_uses_feedback_template() {
        let env = SupportEnvironment(
            appVersion: "1.0", buildNumber: "1",
            osVersion: "14.5", whisperModel: "tiny", micDevice: nil
        )
        let url = SupportLinks.feedbackURL(env: env)
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(q.contains(URLQueryItem(name: "template", value: "feedback.yml")))
    }
}
