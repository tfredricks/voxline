import Foundation
@testable import voxline

/// Test double that captures the outbound request and returns a canned
/// `(data, status)` pair. Used by AnthropicClientTests, OpenAIClientTests, and
/// any other suite that needs to exercise an `HTTPClient` boundary.
/// `stubResponses` are consumed in order before falling back to `stubResponse`.
final class MockHTTPClient: HTTPClient, @unchecked Sendable {
    var capturedRequest: URLRequest?
    var capturedRequests: [URLRequest] = []
    var stubResponse: (data: Data, status: Int) = (Data(), 200)
    var stubResponses: [(Data, Int)] = []
    var stubError: Error?

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        capturedRequest = request
        capturedRequests.append(request)
        if let stubError { throw stubError }
        let (data, status) = stubResponses.isEmpty ? stubResponse : stubResponses.removeFirst()
        let http = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        return (data, http)
    }
}
