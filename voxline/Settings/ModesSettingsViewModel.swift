import Foundation
import Observation

@MainActor
protocol ModesApplier {
    func apply(modes: [Mode])
}

enum ModesSettingsError: Error, Equatable {
    case duplicateBundleID(String)
}

@Observable
@MainActor
final class ModesSettingsViewModel {

    var modes: [Mode] = []
    var lastError: String?

    private let store: ModeStore
    private let applier: ModesApplier

    init(store: ModeStore, applier: ModesApplier) {
        self.store = store
        self.applier = applier
        self.modes = (try? store.load()) ?? ModeStore.shippedDefaults
    }

    /// Convenience for the production code path: uses the canonical app-support file.
    convenience init(applier: ModesApplier) {
        let store = (try? ModeStore()) ?? ModeStore(fileURL: URL(fileURLWithPath: "/dev/null"))
        self.init(store: store, applier: applier)
    }

    func addNewDraft() {
        modes.append(.newDraft())
    }

    func delete(at indexSet: IndexSet) {
        modes.remove(atOffsets: indexSet)
    }

    func addOrUpdate(_ mode: Mode) {
        if let i = modes.firstIndex(where: { $0.bundleID == mode.bundleID }) {
            modes[i] = mode
        } else {
            modes.append(mode)
        }
    }

    func save() throws {
        let ids = modes.map(\.bundleID)
        if let dup = firstDuplicate(in: ids) {
            throw ModesSettingsError.duplicateBundleID(dup)
        }
        try store.save(modes)
        applier.apply(modes: modes)
    }

    private func firstDuplicate(in ids: [String]) -> String? {
        var seen = Set<String>()
        for id in ids where !seen.insert(id).inserted { return id }
        return nil
    }
}
