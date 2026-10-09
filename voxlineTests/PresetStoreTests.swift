import Foundation
import Testing
@testable import voxline

@Suite struct PresetStoreTests {

    private func suite() -> UserDefaults {
        UserDefaults(suiteName: UUID().uuidString)!
    }

    @Test func absent_key_loads_the_three_defaults_in_order() {
        let loaded = PresetStore(defaults: suite()).load()
        #expect(loaded == PresetShortcut.defaults)
        #expect(loaded.map(\.name) == ["Fix grammar", "Make concise", "Make professional"])
        #expect(loaded.map(\.combo) == [
            KeyCombo(keyCode: 18, modifiers: .option),
            KeyCombo(keyCode: 19, modifiers: .option),
            KeyCombo(keyCode: 20, modifiers: .option),
        ])
    }

    @Test func defaults_carry_fixed_ids() {
        #expect(PresetShortcut.defaults.map(\.id) == [
            UUID(uuidString: "6A1D5C0E-0001-4F6B-9B0A-5A1E0C0DE001")!,
            UUID(uuidString: "6A1D5C0E-0002-4F6B-9B0A-5A1E0C0DE002")!,
            UUID(uuidString: "6A1D5C0E-0003-4F6B-9B0A-5A1E0C0DE003")!,
        ])
    }

    @Test func defaults_carry_the_shipped_instructions() {
        #expect(PresetShortcut.defaults.map(\.instruction) == [
            "Fix grammar, spelling, and punctuation. Change nothing else.",
            "Make this more concise. Keep every fact and the original tone.",
            "Rewrite this in a clear, professional tone. Keep the meaning and every fact.",
        ])
    }

    @Test func stored_empty_array_is_respected() {
        let store = PresetStore(defaults: suite())
        store.save([])
        #expect(store.load() == [])
    }

    @Test func save_then_load_round_trips() {
        let store = PresetStore(defaults: suite())
        let custom = PresetShortcut(
            id: UUID(),
            combo: KeyCombo(keyCode: 21, modifiers: [.command, .shift]),
            name: "Translate",
            instruction: "Translate to French."
        )
        store.save(PresetShortcut.defaults + [custom])
        #expect(store.load() == PresetShortcut.defaults + [custom])
    }

    @Test func save_defaults_round_trips() {
        let store = PresetStore(defaults: suite())
        store.save(PresetShortcut.defaults)
        #expect(store.load() == PresetShortcut.defaults)
    }

    @Test func save_writes_json_data_under_the_key() throws {
        let d = suite()
        PresetStore(defaults: d).save(PresetShortcut.defaults)
        let data = try #require(d.data(forKey: PresetStore.key))
        let decoded = try JSONDecoder().decode([PresetShortcut].self, from: data)
        #expect(decoded == PresetShortcut.defaults)
        #expect(PresetStore.key == "voxline.command.presets")
    }

    @Test func row_missing_combo_is_skipped_and_the_rest_load() {
        let d = suite()
        let good = "6A1D5C0E-0009-4F6B-9B0A-5A1E0C0DE009"
        let bad = "6A1D5C0E-000A-4F6B-9B0A-5A1E0C0DE00A"
        let json = """
        [
          {"id": "\(good)", "combo": {"keyCode": 18, "modifiers": 2}, "name": "Keep", "instruction": "Keep me."},
          {"id": "\(bad)", "name": "Broken", "instruction": "No combo."}
        ]
        """
        d.set(Data(json.utf8), forKey: PresetStore.key)
        let loaded = PresetStore(defaults: d).load()
        #expect(loaded.count == 1)
        #expect(loaded.first?.id == UUID(uuidString: good))
        #expect(loaded.first?.combo == KeyCombo(keyCode: 18, modifiers: .option))
        #expect(loaded.first?.name == "Keep")
    }

    @Test func row_with_wrong_field_type_is_skipped_between_valid_rows() {
        let d = suite()
        let json = """
        [
          {"id": "6A1D5C0E-0011-4F6B-9B0A-5A1E0C0DE011", "combo": {"keyCode": 18, "modifiers": 2}, "name": "A", "instruction": "a"},
          {"id": "not-a-uuid", "combo": {"keyCode": 19, "modifiers": 2}, "name": "B", "instruction": "b"},
          7,
          {"id": "6A1D5C0E-0012-4F6B-9B0A-5A1E0C0DE012", "combo": {"keyCode": 20, "modifiers": 2}, "name": "C", "instruction": "c"}
        ]
        """
        d.set(Data(json.utf8), forKey: PresetStore.key)
        #expect(PresetStore(defaults: d).load().map(\.name) == ["A", "C"])
    }

    @Test func non_json_data_loads_the_defaults_without_writing() {
        let d = suite()
        let garbage = Data("not json".utf8)
        d.set(garbage, forKey: PresetStore.key)
        #expect(PresetStore(defaults: d).load() == PresetShortcut.defaults)
        #expect(d.data(forKey: PresetStore.key) == garbage)
    }

    @Test func json_that_is_not_an_array_loads_the_defaults() {
        let d = suite()
        d.set(Data(#"{"presets": []}"#.utf8), forKey: PresetStore.key)
        #expect(PresetStore(defaults: d).load() == PresetShortcut.defaults)
    }

    @Test func non_data_value_loads_the_defaults() {
        let d = suite()
        d.set("oops", forKey: PresetStore.key)
        #expect(PresetStore(defaults: d).load() == PresetShortcut.defaults)
    }
}
