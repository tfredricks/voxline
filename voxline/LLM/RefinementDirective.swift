/// A one-click adjustment the user can apply to a just-completed dictation.
/// The `promptText` is appended to the mode's system prompt for a refine pass;
/// see `LLMService.systemPrompt(mode:refinement:)`.
enum RefinementDirective: String, CaseIterable, Sendable, Equatable {
    case terser
    case longer
    case clearer

    var promptText: String {
        switch self {
        case .terser:
            return "Rewrite to be significantly more concise while preserving the full meaning."
        case .longer:
            return "Expand into fuller, more complete sentences; keep the meaning, add no new claims."
        case .clearer:
            return "Rewrite for clarity, grammar, and flow — fix awkward phrasing without changing the meaning or register."
        }
    }
}
