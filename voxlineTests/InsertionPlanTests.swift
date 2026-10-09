// voxlineTests/InsertionPlanTests.swift
import Foundation
import Testing
@testable import voxline

@Suite struct InsertionPlanTests {

    private func traits(
        _ bundleID: String?,
        attributes: [String] = ["AXValue", "AXSelectedText", "AXSelectedTextRange"],
        settable: Bool = true
    ) -> InsertionPlan.Traits {
        InsertionPlan.Traits(bundleID: bundleID, attributeNames: attributes, selectedTextSettable: settable)
    }

    private func withScratchDefaults(_ body: (UserDefaults) -> Void) {
        let suiteName = "voxline-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(defaults)
    }

    @Test func strategy_raw_values() {
        #expect(InsertStrategy.accessibility.rawValue == "ax")
        #expect(InsertStrategy.paste.rawValue == "paste")
        #expect(InsertStrategy.typing.rawValue == "typing")
    }

    @Test func slack_is_paste_first() {
        #expect(InsertionPlan.strategies(for: traits("com.tinyspeck.slackmacgap")) == [.paste, .typing])
    }

    @Test func every_builtin_paste_first_app_is_paste_first() {
        #expect(InsertionPlan.pasteFirstBundleIDs.count == 17)
        for bundleID in InsertionPlan.pasteFirstBundleIDs {
            #expect(InsertionPlan.strategies(for: traits(bundleID)) == [.paste, .typing], "\(bundleID)")
        }
    }

    @Test func native_field_with_settable_selection_is_ax_first() {
        #expect(InsertionPlan.strategies(for: traits("com.apple.Notes")) == [.accessibility, .paste, .typing])
    }

    @Test func unknown_bundle_is_ax_first() {
        #expect(InsertionPlan.strategies(for: traits(nil)) == [.accessibility, .paste, .typing])
    }

    @Test func web_content_is_paste_first() {
        let classList = traits("com.apple.Notes", attributes: ["AXValue", "AXDOMClassList"])
        let identifier = traits("com.apple.mail", attributes: ["AXDOMIdentifier", "AXSelectedText"])
        #expect(InsertionPlan.strategies(for: classList) == [.paste, .typing])
        #expect(InsertionPlan.strategies(for: identifier) == [.paste, .typing])
    }

    @Test func unsettable_selected_text_is_paste_first() {
        #expect(InsertionPlan.strategies(for: traits("com.apple.Notes", settable: false)) == [.paste, .typing])
    }

    @Test func ax_first_off_restores_paste_ax_typing() {
        let overrides = InsertionPlan.Overrides(axFirst: false)
        #expect(InsertionPlan.strategies(for: traits("com.apple.Notes"), overrides: overrides) == [.paste, .accessibility, .typing])
        #expect(InsertionPlan.strategies(for: traits("com.tinyspeck.slackmacgap"), overrides: overrides) == [.paste, .accessibility, .typing])
    }

    @Test func extra_paste_first_ids_are_paste_first() {
        let overrides = InsertionPlan.Overrides(extraPasteFirst: ["com.example.app"])
        #expect(InsertionPlan.strategies(for: traits("com.example.app"), overrides: overrides) == [.paste, .typing])
        #expect(InsertionPlan.strategies(for: traits("com.example.other"), overrides: overrides) == [.accessibility, .paste, .typing])
    }

    @Test func overrides_keys() {
        #expect(InsertionPlan.Overrides.axFirstKey == "voxline.insert.axFirst")
        #expect(InsertionPlan.Overrides.pasteFirstExtraKey == "voxline.insert.pasteFirstExtra")
    }

    @Test func overrides_load_absent_defaults_to_ax_first() {
        withScratchDefaults { defaults in
            let overrides = InsertionPlan.Overrides.load(from: defaults)
            #expect(overrides.axFirst == true)
            #expect(overrides.extraPasteFirst.isEmpty)
            #expect(overrides == InsertionPlan.Overrides())
        }
    }

    @Test func overrides_load_reads_stored_ax_first_false() {
        withScratchDefaults { defaults in
            defaults.set(false, forKey: InsertionPlan.Overrides.axFirstKey)
            #expect(InsertionPlan.Overrides.load(from: defaults).axFirst == false)
        }
    }

    @Test func overrides_load_reads_stored_ax_first_true() {
        withScratchDefaults { defaults in
            defaults.set(true, forKey: InsertionPlan.Overrides.axFirstKey)
            #expect(InsertionPlan.Overrides.load(from: defaults).axFirst == true)
        }
    }

    @Test func overrides_load_reads_extra_paste_first() {
        withScratchDefaults { defaults in
            defaults.set(["x"], forKey: InsertionPlan.Overrides.pasteFirstExtraKey)
            #expect(InsertionPlan.Overrides.load(from: defaults).extraPasteFirst == ["x"])
        }
    }
}
