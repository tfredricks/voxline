/// Result of an in-place replace. `.replaced` means the prior insertion was
/// selected and pasted over (the user's clipboard was snapshotted and
/// restored). `.fallbackClipboard` means an in-place swap couldn't be verified,
/// so the new text was left on the clipboard for a manual ⌘V.
enum ReplaceOutcome: Equatable, Sendable {
    case replaced(TextInsertionOutcome)
    case fallbackClipboard
}
