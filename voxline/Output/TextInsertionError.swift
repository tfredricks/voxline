// voxline/Output/TextInsertionError.swift
import Foundation

enum TextInsertionError: Error, LocalizedError, Equatable {
    case accessibilityNotGranted
    case clipboardSnapshotUnavailable(String)
    case accessibilityUnavailable(String)
    case accessibilityRejected
    case directTypingUnavailable(String)
    case directTypingRejected
    case secureFieldUnsupported
    case pasteVerificationFailed
    case allStrategiesFailed([String])

    var errorDescription: String? {
        switch self {
        case .accessibilityNotGranted:
            return "Voxline needs Accessibility permission to insert text. Grant access in System Settings → Privacy & Security → Accessibility."
        case .clipboardSnapshotUnavailable(let reason):
            return "Could not safely use the clipboard paste path: \(reason)."
        case .accessibilityUnavailable(let reason):
            return "Accessibility insertion is unavailable: \(reason)."
        case .accessibilityRejected:
            return "The focused field did not appear to accept Accessibility insertion."
        case .directTypingUnavailable(let reason):
            return "Direct typing is unavailable: \(reason)."
        case .directTypingRejected:
            return "The focused field did not appear to accept direct typing."
        case .secureFieldUnsupported:
            return "The focused field is a secure text field. Voxline will not insert dictated text into password inputs."
        case .pasteVerificationFailed:
            return "Voxline could not confirm the paste landed in the focused field. Click the field you want to dictate into and try again."
        case .allStrategiesFailed(let failures):
            return "Text insertion failed. Tried clipboard paste, Accessibility insertion, and direct typing. \(failures.joined(separator: " "))"
        }
    }
}
