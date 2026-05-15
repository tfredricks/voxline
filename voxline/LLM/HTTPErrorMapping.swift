import Foundation

/// Maps an HTTP response from a provider API into either a no-op (success) or
/// the appropriate `LLMError`. Shared by `AnthropicClient` and `OpenAIClient`
/// — the only difference between their previous implementations was the
/// provider tag in log messages, threaded through here as `provider`.
///
/// 401 bodies are intentionally *not* logged: providers sometimes echo a
/// prefix of the offending API key in the error envelope.
func mapHTTPStatus(_ response: HTTPURLResponse, body: Data, provider: LLMProvider) throws {
    switch response.statusCode {
    case 200..<300:
        return
    case 401:
        AppLog.llm.error("\(provider.rawValue): 401 invalid API key")
        throw LLMError.invalidAPIKey
    case 429:
        AppLog.llm.error("\(provider.rawValue): 429 rate limited")
        throw LLMError.rateLimited
    default:
        let text = String(data: body, encoding: .utf8) ?? ""
        let excerpt = text.prefix(200)
        AppLog.llm.error("\(provider.rawValue): HTTP \(response.statusCode) body=\(excerpt)")
        throw LLMError.badStatus(code: response.statusCode, body: text)
    }
}
