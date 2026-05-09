import WhisperKit
import Foundation

// Smoke test only — confirms WhisperKit links. Removed in Task 6.
@MainActor
private enum WhisperKitImportSmokeTest {
    static let supportedTaskTypes: [DecodingTask] = [.transcribe, .translate]
}
