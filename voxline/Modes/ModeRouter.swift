import Foundation

/// Pure-logic lookup of a `Mode` by bundle ID with `*` wildcard fallback.
/// Snapshot-style: pass the current modes in; ModeRouter doesn't observe
/// changes itself (callers re-create or update `.modes` when modes change).
struct ModeRouter {

    var modes: [Mode]

    /// Exact bundle-ID match wins; otherwise return the first wildcard mode;
    /// otherwise nil. A nil `bundleID` (e.g., when no app is frontmost) is
    /// treated the same as "no exact match" — falls through to wildcard.
    func mode(for bundleID: String?) -> Mode? {
        if let bundleID, let exact = modes.first(where: { $0.bundleID == bundleID }) {
            return exact
        }
        return modes.first(where: { $0.bundleID == Mode.wildcardBundleID })
    }
}
