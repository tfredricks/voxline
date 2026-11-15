import Foundation

/// Global custom-vocabulary list. Plain `[String]` persisted to UserDefaults.
/// `@unchecked Sendable`: its only state is a `UserDefaults`, which is documented thread-safe.
struct CustomVocabularyStore: @unchecked Sendable {

    private static let key = "voxline.context.customVocabulary"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> [String] {
        defaults.stringArray(forKey: Self.key) ?? []
    }

    /// Persist `terms` after trimming whitespace, dropping empties, and
    /// deduping while preserving insertion order. Case-sensitive dedupe —
    /// users may want both `cursor` (CLI) and `Cursor` (editor).
    func save(_ terms: [String]) {
        defaults.set(Self.normalize(terms), forKey: Self.key)
    }

    /// Software terms speech engines mishear ("dev" as "dove"). Sent to the
    /// engine as recognition hints only; the cleanup prompt never sees them,
    /// because its canonical-spelling rule would turn a real "dove" into "dev".
    static let developerTerms = [
        "dev", "prod", "staging", "repo", "repos", "localhost", "git", "GitHub", "GitLab",
        "commit", "rebase", "worktree", "monorepo", "PR", "CI", "API", "CLI", "SDK", "JSON",
        "YAML", "SQL", "Postgres", "Redis", "Docker", "Kubernetes", "kubectl", "npm", "pnpm",
        "npx", "Node", "TypeScript", "JavaScript", "Python", "pytest", "SwiftUI", "Xcode",
        "async", "await", "regex", "env", "config", "auth", "OAuth", "JWT", "backend",
        "frontend", "middleware", "endpoint", "webhook", "refactor", "linter", "stdout",
        "stderr", "sudo", "grep", "bash", "zsh", "Homebrew", "AWS", "Terraform", "nginx",
        "Claude Code", "Anthropic", "OpenAI", "LLM", "MCP", "Codex", "VS Code", "changelog",
        "README", "Markdown", "boolean", "enum", "struct", "tuple", "UUID", "SSH", "DNS",
    ]

    private static func normalize(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in terms {
            let t = raw.trimmed
            if t.isEmpty { continue }
            if seen.insert(t).inserted { out.append(t) }
        }
        return out
    }
}
