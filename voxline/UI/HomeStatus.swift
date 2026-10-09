import Foundation

enum HomeStatus {
    static func text(for status: AppStatus, paused: Bool, meetingRecording: Bool) -> String {
        switch status {
        case .recording: return "Recording"
        case .thinking: return "Processing"
        case .downloadingModel(let progress): return "Downloading model — \(Int(progress * 100))%"
        case .preparingModel: return "Preparing model…"
        case .permissionsError(let message), .error(let message): return message
        case .idle:
            if meetingRecording { return "Recording a meeting" }
            return paused ? "Paused" : "Ready"
        }
    }
}
