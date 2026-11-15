import Foundation

/// Picks the names a developer would say aloud but type differently out of
/// text read from the focused window: `camelCase`, `snake_case`,
/// `kebab-case`, and dotted names such as `README.md`. Pure.
enum IdentifierHarvester {

    static let limit = 40
    private static let lengths = 3...40

    private static let token = /[A-Za-z_][A-Za-z0-9_]*(?:[.\-][A-Za-z0-9_]+)*/
    private static let typedDifferently = /[_.\-]|[a-z][A-Z]/

    /// Unique identifiers, at most `limit`. Earlier texts win, and within a
    /// text the last match wins, so text that ends at the cursor yields the
    /// names nearest to it.
    static func identifiers(in texts: [String], limit: Int = limit) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for text in texts {
            for match in text.matches(of: token).reversed() {
                let candidate = String(match.output)
                guard lengths.contains(candidate.count),
                      candidate.contains(typedDifferently),
                      seen.insert(candidate).inserted else { continue }
                out.append(candidate)
                if out.count == limit { return out }
            }
        }
        return out
    }
}
