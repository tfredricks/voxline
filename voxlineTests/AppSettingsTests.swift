import Testing
import Foundation
@testable import voxline

@Suite struct AppSettingsTests {

    /// Per-test isolated suite so we don't trample the user's real defaults.
    private func makeDefaults() -> UserDefaults {
        let suiteName = "voxline-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test func unset_provider_defaults_to_anthropic() {
        let s = AppSettings(defaults: makeDefaults())
        #expect(s.llmProvider == .anthropic)
    }

    @Test func set_provider_round_trips() {
        let defaults = makeDefaults()
        var s = AppSettings(defaults: defaults)
        s.llmProvider = .openai
        #expect(AppSettings(defaults: defaults).llmProvider == .openai)
    }

    @Test func default_model_per_provider_matches_spec() {
        let defaults = makeDefaults()
        var s = AppSettings(defaults: defaults)
        s.llmProvider = .anthropic
        #expect(s.llmModel == "claude-haiku-4-5")
        s.llmProvider = .openai
        #expect(s.llmModel == "gpt-4o-mini")
    }

    @Test func explicit_model_override_persists_across_provider_switch() {
        let defaults = makeDefaults()
        var s = AppSettings(defaults: defaults)
        s.llmProvider = .anthropic
        s.llmModel = "claude-3-5-sonnet-latest"
        #expect(s.llmModel == "claude-3-5-sonnet-latest")
        s.llmProvider = .openai
        // Changing provider clears the model override (spec default returns).
        #expect(s.llmModel == "gpt-4o-mini")
    }
}
