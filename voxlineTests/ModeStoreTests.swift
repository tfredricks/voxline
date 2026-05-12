import Testing
import Foundation
@testable import voxline

@Suite struct ModeStoreTests {

    /// Build a ModeStore against a fresh per-test directory so we don't
    /// touch the real Application Support modes.json.
    private func makeStore() -> (store: ModeStore, dir: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxline-modestore-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("modes.json")
        return (ModeStore(fileURL: url), dir)
    }

    @Test func load_on_missing_file_returns_shipped_defaults_and_creates_file() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let modes = try store.load()
        #expect(modes == ModeStore.shippedDefaults)
        #expect(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    @Test func save_then_load_round_trip_for_custom_mode() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Custom modes (unknown bundle IDs) pass through reconcile untouched.
        let custom = [
            Mode(bundleID: "com.apple.notes", displayName: "Notes", prompt: "casual", model: nil, temperature: nil)
        ]
        try store.save(custom)
        let loaded = try store.load()
        #expect(loaded == custom)
    }

    @Test func shipped_defaults_include_wildcard_fallback() {
        #expect(ModeStore.shippedDefaults.contains(where: { $0.bundleID == Mode.wildcardBundleID }))
    }

    @Test func shipped_defaults_cover_slack_mail_cursor() {
        let ids = Set(ModeStore.shippedDefaults.map(\.bundleID))
        #expect(ids.contains("com.tinyspeck.slackmacgap"))
        #expect(ids.contains("com.apple.mail"))
        #expect(ids.contains("com.todesktop.230313mzl4w4u92"))
    }

    @Test func shipped_defaults_cover_terminal_webex_office_vscode() {
        let ids = Set(ModeStore.shippedDefaults.map(\.bundleID))
        #expect(ids.contains("com.apple.Terminal"))
        #expect(ids.contains("Cisco-Systems.Spark"))
        #expect(ids.contains("com.microsoft.Word"))
        #expect(ids.contains("com.microsoft.Excel"))
        #expect(ids.contains("com.microsoft.Powerpoint"))
        #expect(ids.contains("com.microsoft.Outlook"))
        #expect(ids.contains("com.microsoft.VSCode"))
    }

    @Test func shipped_defaults_route_apps_by_category() {
        // Each shipped bundle ID should resolve to the prompt that matches its
        // category. If you remap an app's category, update both ModeStore and
        // this test together.
        func prompt(for id: String) -> String? {
            ModeStore.shippedDefaults.first(where: { $0.bundleID == id })?.prompt
        }

        // Chat apps
        #expect(prompt(for: "com.tinyspeck.slackmacgap") == ModeStore.chatPrompt)
        #expect(prompt(for: "Cisco-Systems.Spark")       == ModeStore.chatPrompt)
        #expect(prompt(for: "us.zoom.xos")               == ModeStore.chatPrompt)
        #expect(prompt(for: "com.microsoft.teams2")      == ModeStore.chatPrompt)
        #expect(prompt(for: "com.microsoft.teams")       == ModeStore.chatPrompt)

        // Email apps
        #expect(prompt(for: "com.apple.mail")            == ModeStore.emailPrompt)
        #expect(prompt(for: "com.microsoft.Outlook")     == ModeStore.emailPrompt)

        // Writing apps
        #expect(prompt(for: "com.microsoft.Word")        == ModeStore.writingPrompt)
        #expect(prompt(for: "com.apple.iWork.Pages")     == ModeStore.writingPrompt)

        // Non-prose Office stays on defaultPrompt
        #expect(prompt(for: "com.microsoft.Excel")       == ModeStore.defaultPrompt)
        #expect(prompt(for: "com.microsoft.Powerpoint")  == ModeStore.defaultPrompt)

        // Code/terminal
        #expect(prompt(for: "com.apple.Terminal")        == ModeStore.codePrompt)
        #expect(prompt(for: "com.microsoft.VSCode")      == ModeStore.codePrompt)
        #expect(prompt(for: "com.todesktop.230313mzl4w4u92") == ModeStore.codePrompt)

        // Wildcard fallback
        #expect(prompt(for: Mode.wildcardBundleID)       == ModeStore.defaultPrompt)
    }

    @Test func wildcard_default_is_last_so_exact_matches_win() {
        // ModeRouter scans from the front, so the `*` catch-all must sit at the
        // end — otherwise a wildcard mode could be returned ahead of an exact
        // bundle-ID match for any newly-added entry.
        #expect(ModeStore.shippedDefaults.last?.bundleID == Mode.wildcardBundleID)
    }

    // MARK: - reconcileShippedPrompts

    @Test func reconcile_overwrites_prompts_for_shipped_bundle_ids() {
        // User's modes.json has stale prompts (old wording) but correct
        // bundle IDs. Reconcile replaces them with the current shipped prompts
        // regardless of what was there.
        let stale = [
            Mode(bundleID: "com.tinyspeck.slackmacgap", displayName: "Slack",
                 prompt: "anything stale",
                 model: nil, temperature: nil),
            Mode(bundleID: "com.apple.Terminal", displayName: "Terminal",
                 prompt: "also stale, even custom",
                 model: nil, temperature: nil),
            Mode(bundleID: Mode.wildcardBundleID, displayName: "Default",
                 prompt: "stale wildcard",
                 model: nil, temperature: nil),
        ]
        let reconciled = ModeStore.reconcileShippedPrompts(stale)

        #expect(reconciled.first { $0.bundleID == "com.tinyspeck.slackmacgap" }?.prompt == ModeStore.chatPrompt)
        #expect(reconciled.first { $0.bundleID == "com.apple.Terminal" }?.prompt == ModeStore.codePrompt)
        #expect(reconciled.first { $0.bundleID == Mode.wildcardBundleID }?.prompt == ModeStore.defaultPrompt)
    }

    @Test func reconcile_preserves_per_mode_overrides_for_shipped_apps() {
        // Only the prompt is replaced. displayName, model, temperature stay
        // exactly as the user had them.
        let userTuned = [
            Mode(bundleID: "com.apple.mail", displayName: "My Mail",
                 prompt: "stale", model: "gpt-5-mini", temperature: 0.4),
        ]
        let reconciled = ModeStore.reconcileShippedPrompts(userTuned)
        let mail = try! #require(reconciled.first)
        #expect(mail.prompt == ModeStore.emailPrompt)
        #expect(mail.displayName == "My Mail")
        #expect(mail.model == "gpt-5-mini")
        #expect(mail.temperature == 0.4)
    }

    @Test func reconcile_leaves_unknown_bundle_ids_alone() {
        let custom = [
            Mode(bundleID: "com.example.MyApp", displayName: "MyApp",
                 prompt: "anything goes", model: nil, temperature: nil),
        ]
        #expect(ModeStore.reconcileShippedPrompts(custom) == custom)
    }

    @Test func load_rewrites_disk_when_prompts_drift() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Seed with stale prompts.
        let stale = [
            Mode(bundleID: "com.tinyspeck.slackmacgap", displayName: "Slack",
                 prompt: "old wording", model: nil, temperature: nil),
        ]
        try store.save(stale)

        let loaded = try store.load()
        #expect(loaded.first?.prompt == ModeStore.chatPrompt)

        // Reload from disk via a fresh store to prove the rewrite persisted.
        let fresh = ModeStore(fileURL: store.fileURL)
        let again = try fresh.load()
        #expect(again.first?.prompt == ModeStore.chatPrompt)
    }
}
