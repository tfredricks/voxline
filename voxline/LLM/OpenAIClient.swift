// voxline/LLM/OpenAIClient.swift
import Foundation

struct OpenAIClient: LLMClient {

    static let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!

    let apiKey: String
    let http: HTTPClient

    init(apiKey: String, http: HTTPClient = URLSessionHTTPClient()) {
        self.apiKey = apiKey
        self.http = http
    }

    func cleanup(_ request: LLMRequest) async throws -> String {
        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "content-type")

        // gpt-5 reasoning models reject `max_tokens` on chat completions and
        // require `max_completion_tokens`. The newer field is also accepted by
        // older models (gpt-4.1, gpt-4o, ...), so we always send it.
        var body: [String: Any] = [
            "model": request.model,
            "max_completion_tokens": request.maxOutputTokens,
            "messages": [
                ["role": "system", "content": request.systemPrompt],
                ["role": "user", "content": request.userPrompt]
            ]
        ]
        if let t = request.temperature { body["temperature"] = t }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        AppLog.llm.debug("openai POST model=\(request.model)")
        let (data, response): (Data, HTTPURLResponse)
        do {
            (data, response) = try await http.send(req)
        } catch {
            throw LLMError.network(error)
        }
        AppLog.llm.debug("openai HTTP \(response.statusCode) (bytes=\(data.count))")
        try mapHTTPStatus(response, body: data, provider: .openai)

        struct Envelope: Decodable {
            let choices: [Choice]
            struct Choice: Decodable {
                let message: Message
                let finishReason: String?
                struct Message: Decodable {
                    let content: String?
                }
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
        guard let first = env.choices.first else {
            throw LLMError.badResponseShape(reason: "no choices in response")
        }
        switch first.finishReason {
        case "length":         throw LLMError.truncated
        case "content_filter": throw LLMError.refused
        default:               break
        }
        guard let content = first.message.content,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw LLMError.badResponseShape(reason: "empty message content")
        }
        return content
    }
}
