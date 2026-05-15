import Foundation

struct AnthropicClient: LLMClient {

    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let apiVersion = "2023-06-01"

    let apiKey: String
    let http: HTTPClient

    init(apiKey: String, http: HTTPClient = URLSessionHTTPClient()) {
        self.apiKey = apiKey
        self.http = http
    }

    func cleanup(_ request: LLMRequest) async throws -> String {
        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")

        var body: [String: Any] = [
            "model": request.model,
            "max_tokens": request.maxOutputTokens,
            "system": request.systemPrompt,
            "messages": [["role": "user", "content": request.userPrompt]]
        ]
        if let t = request.temperature { body["temperature"] = t }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        AppLog.llm.debug("anthropic POST model=\(request.model)")
        let (data, response): (Data, HTTPURLResponse)
        do {
            (data, response) = try await http.send(req)
        } catch {
            throw LLMError.network(error)
        }
        AppLog.llm.debug("anthropic HTTP \(response.statusCode) (bytes=\(data.count))")
        try mapStatus(response: response, body: data)

        return try parseTextBlocks(from: data)
    }

    private func mapStatus(response: HTTPURLResponse, body: Data) throws {
        switch response.statusCode {
        case 200..<300: return
        case 401:
            // Body intentionally not logged: 401 responses can echo the
            // offending API key prefix.
            AppLog.llm.error("anthropic: 401 invalid API key")
            throw LLMError.invalidAPIKey
        case 429:
            AppLog.llm.error("anthropic: 429 rate limited")
            throw LLMError.rateLimited
        default:
            let text = String(data: body, encoding: .utf8) ?? ""
            let excerpt = text.prefix(200)
            AppLog.llm.error("anthropic: HTTP \(response.statusCode) body=\(excerpt)")
            throw LLMError.badStatus(code: response.statusCode, body: text)
        }
    }

    private func parseTextBlocks(from data: Data) throws -> String {
        struct Envelope: Decodable {
            let content: [Block]
            struct Block: Decodable {
                let type: String
                let text: String?
            }
        }
        let env: Envelope
        do {
            env = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw LLMError.badResponseShape(reason: "JSON decode failed: \(error.localizedDescription)")
        }
        let text = env.content.compactMap { $0.type == "text" ? $0.text : nil }.joined()
        if text.isEmpty {
            throw LLMError.badResponseShape(reason: "no text blocks in response")
        }
        return text
    }
}
