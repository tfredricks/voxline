import Foundation
import Observation

enum AppStatus: Equatable {
    case idle
    case recording
    case thinking
    case error(String)
}

@Observable
final class AppState {
    var status: AppStatus = .idle
}
