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
        try mapHTTPStatus(response, body: data, provider: "anthropic")

        return try parseTextBlocks(from: data)
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
