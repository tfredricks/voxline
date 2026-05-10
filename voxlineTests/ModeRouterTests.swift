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

    // MARK: - Field-aware routing

    @Test func exact_bundle_plus_field_kind_beats_bundle_only() {
        let router = ModeRouter(modes: [
            Mode(bundleID: "com.tinyspeck.slackmacgap", displayName: "Slack", prompt: "slack", model: nil, temperature: nil, fieldKind: nil),
            Mode(bundleID: "com.tinyspeck.slackmacgap", displayName: "Slack search", prompt: "slack-search", model: nil, temperature: nil, fieldKind: .search),
            Mode(bundleID: "*", displayName: "Default", prompt: "default", model: nil, temperature: nil)
        ])
        let field = FocusedField(role: "AXTextField", subrole: "AXSearchField")
        #expect(router.mode(for: "com.tinyspeck.slackmacgap", field: field)?.prompt == "slack-search")
    }

    @Test func bundle_only_match_when_field_kind_doesnt_match() {
        // A search-specific Slack mode exists, but the focused field is plain text —
        // the bundle's catch-all (fieldKind == nil) should win.
        let router = ModeRouter(modes: [
            Mode(bundleID: "com.tinyspeck.slackmacgap", displayName: "Slack search", prompt: "slack-search", model: nil, temperature: nil, fieldKind: .search),
            Mode(bundleID: "com.tinyspeck.slackmacgap", displayName: "Slack", prompt: "slack", model: nil, temperature: nil, fieldKind: nil),
            Mode(bundleID: "*", displayName: "Default", prompt: "default", model: nil, temperature: nil)
        ])
        let field = FocusedField(role: "AXTextArea", subrole: nil)
        #expect(router.mode(for: "com.tinyspeck.slackmacgap", field: field)?.prompt == "slack")
    }

    @Test func wildcard_field_specific_beats_wildcard_catchall() {
        let router = ModeRouter(modes: [
            Mode(bundleID: "*", displayName: "Default", prompt: "default", model: nil, temperature: nil, fieldKind: nil),
            Mode(bundleID: "*", displayName: "Any search", prompt: "any-search", model: nil, temperature: nil, fieldKind: .search)
        ])
        let field = FocusedField(role: "AXTextField", subrole: "AXSearchField")
        #expect(router.mode(for: "com.unknown.app", field: field)?.prompt == "any-search")
    }

    @Test func bundle_match_with_no_field_specific_falls_through_to_wildcard_field_specific() {
        // No Slack-specific search mode; wildcard search mode wins over Slack catch-all
        // for a search field? No — bundle exact match (Slack catch-all) is more specific
        // than wildcard. Verify priority order.
        let router = ModeRouter(modes: [
            Mode(bundleID: "com.tinyspeck.slackmacgap", displayName: "Slack", prompt: "slack", model: nil, temperature: nil, fieldKind: nil),
            Mode(bundleID: "*", displayName: "Any search", prompt: "any-search", model: nil, temperature: nil, fieldKind: .search)
        ])
        let field = FocusedField(role: "AXTextField", subrole: "AXSearchField")
        // Bundle exact (step 2) beats wildcard field-specific (step 3).
        #expect(router.mode(for: "com.tinyspeck.slackmacgap", field: field)?.prompt == "slack")
    }

    @Test func nil_field_skips_field_specific_modes() {
        let router = ModeRouter(modes: [
            Mode(bundleID: "com.tinyspeck.slackmacgap", displayName: "Slack search only", prompt: "slack-search", model: nil, temperature: nil, fieldKind: .search),
            Mode(bundleID: "*", displayName: "Default", prompt: "default", model: nil, temperature: nil)
        ])
        // Inspector returned nil — must not pick the search-only Slack mode.
        #expect(router.mode(for: "com.tinyspeck.slackmacgap", field: nil)?.prompt == "default")
    }
}
