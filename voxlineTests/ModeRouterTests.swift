import Testing
@testable import voxline

@Suite struct ModeRouterTests {

    private let modes: [Mode] = [
        Mode(bundleID: "com.tinyspeck.slackmacgap", displayName: "Slack", prompt: "slack-prompt", model: nil, temperature: nil),
        Mode(bundleID: "com.apple.mail", displayName: "Mail", prompt: "mail-prompt", model: nil, temperature: nil),
        Mode(bundleID: Mode.wildcardBundleID, displayName: "Default", prompt: "default-prompt", model: nil, temperature: nil)
    ]

    @Test func exact_bundle_id_match_wins() {
        let router = ModeRouter(modes: modes)
        #expect(router.mode(for: "com.tinyspeck.slackmacgap")?.prompt == "slack-prompt")
        #expect(router.mode(for: "com.apple.mail")?.prompt == "mail-prompt")
    }

    @Test func unknown_bundle_id_falls_back_to_wildcard() {
        let router = ModeRouter(modes: modes)
        #expect(router.mode(for: "com.unknown.app")?.prompt == "default-prompt")
    }

    @Test func nil_bundle_id_falls_back_to_wildcard() {
        let router = ModeRouter(modes: modes)
        #expect(router.mode(for: nil)?.prompt == "default-prompt")
    }

    @Test func no_wildcard_no_match_returns_nil() {
        let router = ModeRouter(modes: [
            Mode(bundleID: "com.apple.mail", displayName: "Mail", prompt: "mail", model: nil, temperature: nil)
        ])
        #expect(router.mode(for: "com.unknown.app") == nil)
    }

    @Test func empty_modes_returns_nil() {
        let router = ModeRouter(modes: [])
        #expect(router.mode(for: "anything") == nil)
    }
}
