import Foundation

/// Pure-logic lookup of a `Mode` by bundle ID + optional focused-field hint,
/// with `*` wildcard fallback. Snapshot-style: pass the current modes in;
/// ModeRouter doesn't observe changes itself (callers re-create or update
/// `.modes` when modes change).
struct ModeRouter: ModeResolving {

    var modes: [Mode]

    /// Resolution priority (most → least specific):
    ///   1. exact bundleID + matching `fieldKind`
    ///   2. exact bundleID + `fieldKind == nil` (the app's catch-all)
    ///   3. wildcard bundleID + matching `fieldKind`
    ///   4. wildcard bundleID + `fieldKind == nil`
    /// A nil `bundleID` (no frontmost app) skips steps 1 and 2.
    /// A nil `field` (inspector unavailable) skips steps 1 and 3.
    func mode(for bundleID: String?, field: FocusedField? = nil) -> Mode? {
        let kind = field?.kind

        if let bundleID, let kind,
           let exact = modes.first(where: { $0.bundleID == bundleID && $0.fieldKind == kind }) {
            return exact
        }
        if let bundleID,
           let exact = modes.first(where: { $0.bundleID == bundleID && $0.fieldKind == nil }) {
            return exact
        }
        if let kind,
           let wildcard = modes.first(where: { $0.bundleID == Mode.wildcardBundleID && $0.fieldKind == kind }) {
            return wildcard
        }
        return modes.first(where: { $0.bundleID == Mode.wildcardBundleID && $0.fieldKind == nil })
    }
}
