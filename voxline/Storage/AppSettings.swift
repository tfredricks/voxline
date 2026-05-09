import Foundation

/// Thin wrapper around UserDefaults for non-secret user preferences.
/// Secrets live in `Keychain`.
struct AppSettings {

    enum Key {
        static let provider = "voxline.llm.provider"
        static let model = "voxline.llm.model"
    }

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// LLM provider choice. Defaults to .anthropic.
    /// Setting a new provider clears any model override so the spec default
    /// for the new provider takes over (a model id from one provider is
    /// almost never valid for another).
    var llmProvider: LLMProvider {
        get {
            guard
                let raw = defaults.string(forKey: Key.provider),
                let p = LLMProvider(rawValue: raw)
            else { return .anthropic }
            return p
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.provider)
            defaults.removeObject(forKey: Key.model)
        }
    }

    /// Active LLM model id. Falls back to the spec default for the current
    /// provider when no override is set.
    var llmModel: String {
        get { defaults.string(forKey: Key.model) ?? llmProvider.defaultModel }
        set { defaults.set(newValue, forKey: Key.model) }
    }
}
