import Testing
import Foundation
@testable import voxline

@Suite @MainActor struct ModesSettingsViewModelTests {

    private func tempStore() throws -> ModeStore {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("voxline-modes-\(UUID().uuidString).json")
        return ModeStore(fileURL: url)
    }

    @Test func loads_modes_from_store_on_init() throws {
        let store = try tempStore()
        try store.save([
            Mode(bundleID: "com.foo", displayName: "Foo", prompt: "p", model: nil, temperature: nil),
            Mode(bundleID: "*", displayName: "Default", prompt: "d", model: nil, temperature: nil)
        ])

        let vm = ModesSettingsViewModel(store: store, applier: NoopApplier())
        #expect(vm.modes.count == 2)
        #expect(vm.modes.first?.bundleID == "com.foo")
    }

    @Test func add_appends_a_draft_mode() throws {
        let vm = ModesSettingsViewModel(store: try tempStore(), applier: NoopApplier())
        let before = vm.modes.count
        vm.addNewDraft()
        #expect(vm.modes.count == before + 1)
        #expect(vm.modes.last?.bundleID == "")
    }

    @Test func delete_removes_at_index() throws {
        let store = try tempStore()
        try store.save([
            Mode(bundleID: "com.a", displayName: "A", prompt: "x", model: nil, temperature: nil),
            Mode(bundleID: "com.b", displayName: "B", prompt: "y", model: nil, temperature: nil)
        ])
        let vm = ModesSettingsViewModel(store: store, applier: NoopApplier())
        vm.delete(at: IndexSet(integer: 0))
        #expect(vm.modes.count == 1)
        #expect(vm.modes.first?.bundleID == "com.b")
    }

    @Test func save_persists_and_calls_applier() throws {
        let store = try tempStore()
        let applier = RecordingModesApplier()
        let vm = ModesSettingsViewModel(store: store, applier: applier)

        vm.modes = [
            Mode(bundleID: "com.zap", displayName: "Zap", prompt: "p", model: nil, temperature: nil)
        ]
        try vm.save()

        let reread = try store.load()
        #expect(reread.first?.bundleID == "com.zap")
        #expect(applier.applied?.first?.bundleID == "com.zap")
    }

    @Test func save_rejects_duplicate_bundle_ids() throws {
        let vm = ModesSettingsViewModel(store: try tempStore(), applier: NoopApplier())
        vm.modes = [
            Mode(bundleID: "com.dup", displayName: "A", prompt: "p", model: nil, temperature: nil),
            Mode(bundleID: "com.dup", displayName: "B", prompt: "q", model: nil, temperature: nil)
        ]
        #expect(throws: ModesSettingsError.self) { try vm.save() }
        do {
            try vm.save()
            Issue.record("Expected save to throw")
        } catch let ModesSettingsError.duplicateBundleID(id) {
            #expect(id == "com.dup")
        } catch {
            Issue.record("Wrong error type: \(error)")
        }
    }
}

private struct NoopApplier: ModesApplier {
    func apply(modes: [Mode]) {}
}

@MainActor
private final class RecordingModesApplier: ModesApplier {
    var applied: [Mode]?
    func apply(modes: [Mode]) { applied = modes }
}
