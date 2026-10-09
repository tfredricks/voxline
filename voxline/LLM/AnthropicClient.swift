import Foundation

struct AnthropicClient: LLMClient {

    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let apiVersion = "2023-06-01"

    let apiKey: String
    let http: HTTPClient
    let support: StructuredOutputSupport

    init(apiKey: String, http: HTTPClient = URLSessionHTTPClient(), structuredOutput: StructuredOutputSupport = .shared) {
        self.apiKey = apiKey
        self.http = http
        self.support = structuredOutput
    }

    /// Sends `request`, with `output_config.format` when it carries a
    /// structured output the model hasn't rejected. A 400 naming the field
    /// marks the model in `support` and retries once prompt-only.
    func complete(_ request: LLMRequest) async throws -> String {
        let sendsFormat = request.structuredOutput != nil && !support.rejects(request.model)
        do {
            return try await send(request)
        } catch let error as LLMError where sendsFormat && StructuredOutputSupport.isStructuredOutputRejection(error) {
            support.markRejected(request.model)
            AppLog.llm.notice("\(request.model, privacy: .public) rejected structured output; retrying prompt-only")
            var promptOnly = request
            promptOnly.structuredOutput = nil
            return try await send(promptOnly)
        }
    }

    private func send(_ request: LLMRequest) async throws -> String {
        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body(for: request))

        AppLog.llm.debug("anthropic POST model=\(request.model)")
        let (data, response): (Data, HTTPURLResponse)
        do {
            (data, response) = try await http.send(req)
        } catch {
            throw LLMError.network(error)
        }
        AppLog.llm.debug("anthropic HTTP \(response.statusCode) (bytes=\(data.count))")
        try mapHTTPStatus(response, body: data, provider: .anthropic)

        return try parseTextBlocks(from: data)
    }

    private func body(for request: LLMRequest) throws -> [String: Any] {
        var body: [String: Any] = [
            "model": request.model,
            "max_tokens": request.maxOutputTokens,
            "system": request.systemPrompt,
            "messages": [["role": "user", "content": request.userPrompt]]
        ]
        var outputConfig: [String: Any] = [:]
        if LLMRequest.anthropicThinksByDefault(request.model) { outputConfig["effort"] = "low" }
        if let structured = request.structuredOutput, !support.rejects(request.model) {
            outputConfig["format"] = ["type": "json_schema", "schema": try structured.schemaObject()]
        }
        if !outputConfig.isEmpty { body["output_config"] = outputConfig }
        if let t = request.temperature, !LLMRequest.anthropicThinksByDefault(request.model) { body["temperature"] = t }
        return body
    }

    private func parseTextBlocks(from data: Data) throws -> String {
        struct Envelope: Decodable {
            let content: [Block]
            let stopReason: String?
            struct Block: Decodable {
                let type: String
                let text: String?
            }
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let env: Envelope
        do {
            env = try decoder.decode(Envelope.self, from: data)
        } catch {
            throw LLMError.badResponseShape(reason: "JSON decode failed: \(error.localizedDescription)")
        }
        switch env.stopReason {
        case "max_tokens": throw LLMError.truncated
        case "refusal":    throw LLMError.refused
        default:           break
        }
        let text = env.content.compactMap { $0.type == "text" ? $0.text : nil }.joined()
        if text.isEmpty {
            throw LLMError.badResponseShape(reason: "no text blocks in response")
        }
        return text
    }
}
