import Foundation

/// Remembers model ids that returned 400 for the structured-output field, for the
/// rest of the process. Shared across both clients.
final class StructuredOutputSupport: @unchecked Sendable {
    static let shared = StructuredOutputSupport()

    private let lock = NSLock()
    private var rejected: Set<String> = []

    init() {}

    func rejects(_ model: String) -> Bool {
        lock.withLock { rejected.contains(model) }
    }

    func markRejected(_ model: String) {
        lock.withLock { _ = rejected.insert(model) }
    }

    private static let fieldNames = ["output_config", "response_format", "json_schema"]

    /// 400 whose body mentions output_config, response_format, or json_schema.
    static func isStructuredOutputRejection(_ error: LLMError) -> Bool {
        guard case .badStatus(400, let body) = error else { return false }
        let lowered = body.lowercased()
        return fieldNames.contains { lowered.contains($0) }
    }
}
