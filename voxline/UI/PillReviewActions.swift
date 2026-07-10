import Foundation

/// Callbacks the review pill invokes. Wired to `CapturePipeline` in
/// `voxlineApp`. Defaults are no-ops so previews / tests can omit them.
@MainActor
struct PillReviewActions {
    var refine: (RefinementDirective) -> Void
    var dismiss: () -> Void
    var hoverChanged: (Bool) -> Void

    // Explicit `nonisolated` init: default-argument expressions (e.g. the
    // `actions: PillReviewActions = PillReviewActions()` default parameter in
    // `RecordingPillWindow.show`) are evaluated in a non-isolated context even
    // when the caller/callee are `@MainActor`, so the implicit memberwise init
    // — which would otherwise inherit this struct's `@MainActor` isolation —
    // can't be called there. The stored properties are plain closures, so
    // constructing one doesn't touch actor-isolated state.
    nonisolated init(
        refine: @escaping (RefinementDirective) -> Void = { _ in },
        dismiss: @escaping () -> Void = {},
        hoverChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        self.refine = refine
        self.dismiss = dismiss
        self.hoverChanged = hoverChanged
    }
}
