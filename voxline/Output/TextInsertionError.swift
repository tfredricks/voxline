// voxline/Output/TextInsertionError.swift
import Foundation

enum TextInsertionError: Error, LocalizedError, Equatable {
    case accessibilityNotGranted
    case secureFieldUnsupported
    case pasteVerificationFailed
    /// One reason per strategy that was tried, in order, for the log; the
    /// user sees only that the text wasn't inserted.
    case allStrategiesFailed([String])

    var errorDescription: String? {
        switch self {
        case .accessibilityNotGranted:
            return "Voxline needs Accessibility permission to insert text. Grant access in System Settings → Privacy & Security → Accessibility."
        case .secureFieldUnsupported:
            return "The focused field is a secure text field. Voxline will not insert dictated text into password inputs."
        case .pasteVerificationFailed:
            return "Voxline could not confirm the paste landed in the focused field. Click the field you want to dictate into and try again."
        case .allStrategiesFailed:
            return "Couldn't insert the text."
        }
    }
}
