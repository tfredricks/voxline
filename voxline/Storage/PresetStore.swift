import Foundation

/// Preset shortcuts persisted as JSON in UserDefaults. An absent key loads the
/// shipped defaults and a stored empty array is respected. Decoding is
/// field-tolerant: an invalid row is skipped and the rest load, so one bad row
/// can't discard the user's other presets.
struct PresetStore {

    static let key = "voxline.command.presets"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> [PresetShortcut] {
        guard let stored = defaults.object(forKey: Self.key) else { return PresetShortcut.defaults }
        guard let data = stored as? Data,
              let rows = try? JSONDecoder().decode([Tolerant<PresetShortcut>].self, from: data)
        else {
            AppLog.hotkey.error("presets: unreadable store, using defaults")
            return PresetShortcut.defaults
        }
        let presets = rows.compactMap(\.value)
        if presets.count != rows.count {
            AppLog.hotkey.error("presets: skipped \(rows.count - presets.count, privacy: .public) invalid rows")
        }
        return presets
    }

    func save(_ presets: [PresetShortcut]) {
        guard let data = try? JSONEncoder().encode(presets) else {
            AppLog.hotkey.error("presets: encode failed, nothing saved")
            return
        }
        defaults.set(data, forKey: Self.key)
    }
}

private struct Tolerant<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}
