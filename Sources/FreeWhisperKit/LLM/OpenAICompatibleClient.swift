import Foundation

/// Minimal client for the OpenAI chat-completions shape.
///
/// Deliberately not the OpenAI SDK: the whole point is that any endpoint
/// speaking this shape works, including Ollama and LM Studio, and a hand-rolled
/// request keeps that promise honest.
public struct OpenAICompatibleClient: ChatCompleting {
    public struct Message: Codable, Sendable {
        public let role: String
        public let content: String

        public init(role: String, content: String) {
            self.role = role
            self.content = content
        }

        public static func system(_ content: String) -> Message { .init(role: "system", content: content) }
        public static func user(_ content: String) -> Message { .init(role: "user", content: content) }
    }

    public enum ClientError: LocalizedError {
        case invalidURL(String)
        case missingAPIKey(String)
        case http(status: Int, body: String)
        case emptyResponse
        case cannotReachLocalServer(String)

        public var errorDescription: String? {
            switch self {
            case .invalidURL(let url):
                "'\(url)' is not a valid endpoint URL."
            case .missingAPIKey(let provider):
                "\(provider) needs an API key. Add one in Settings."
            case .http(let status, let body):
                "The model provider returned \(status): \(body.prefix(200))"
            case .emptyResponse:
                "The model returned nothing."
            case .cannotReachLocalServer(let name):
                "Could not reach \(name). Is it running?"
            }
        }
    }

    private let provider: LLMProvider
    private let session: URLSession

    public init(provider: LLMProvider, session: URLSession = EgressSession.shared) {
        self.provider = provider
        self.session = session
    }

    public func complete(
        messages: [Message],
        temperature: Double = 0.2,
        maxTokens: Int? = nil
    ) async throws -> String {
        guard let url = provider.chatCompletionsURL else {
            throw ClientError.invalidURL(provider.baseURL)
        }

        var body: [String: Any] = [
            "model": provider.model,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "temperature": temperature,
            "stream": false,
        ]
        if let maxTokens { body["max_tokens"] = maxTokens }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        // Local models on modest hardware are slow; a default 60s timeout will
        // fail a long transcript that would otherwise have completed.
        request.timeoutInterval = 300

        if let key = provider.apiKey, !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        } else if provider.keychainAccount != nil, !provider.isLocal {
            throw ClientError.missingAPIKey(provider.name)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if provider.isLocal {
                throw ClientError.cannotReachLocalServer(provider.name)
            }
            throw error
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ClientError.http(
                status: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }

        return try Self.extractContent(from: data)
    }

    static func extractContent(from data: Data) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String
        else {
            throw ClientError.emptyResponse
        }

        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ClientError.emptyResponse }
        return trimmed
    }

    /// Cheap liveness check for the Settings pane.
    public func testConnection() async throws -> String {
        try await complete(
            messages: [.user("Reply with the single word: ok")],
            temperature: 0,
            maxTokens: 10
        )
    }
}
