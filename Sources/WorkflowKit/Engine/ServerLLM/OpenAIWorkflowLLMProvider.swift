import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

// MARK: - OpenAIWorkflowLLMProvider

/// `WorkflowLLMProvider` conformer that POSTs to OpenAI's
/// `/chat/completions` endpoint. Works with the canonical
/// `api.openai.com` host AND Azure-hosted OpenAI deployments —
/// the latter just need a custom `baseURL` (set in the provider
/// editor) and the same Bearer-token auth.
///
/// Stateless and `Sendable` — every call builds a fresh request
/// from the stored config so the same instance can be reused
/// across LLM steps without worrying about request ordering.
public struct OpenAIWorkflowLLMProvider: WorkflowLLMProvider {
    // MARK: Lifecycle

    public init(
        baseURL: URL,
        model: String,
        token: String,
        temperature: Double,
        maxTokens: Int? = nil,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.model = model
        self.token = token
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.session = session
    }

    // MARK: Public

    public func generate(
        prompt: String,
        hint _: ModelFamilyHint,
        maxTokens: Int?
    ) async throws -> String {
        let url = self.baseURL.appendingPathComponent("chat/completions")
        var body: [String: Any] = [
            "model": self.model,
            "messages": [["role": "user", "content": prompt]],
            "temperature": self.temperature,
        ]
        if let tokens = maxTokens ?? self.maxTokens {
            body["max_tokens"] = tokens
        }
        let data = try await ServerLLMHTTP.postJSON(
            url: url,
            body: body,
            headers: ["Authorization": "Bearer \(self.token)"],
            session: self.session
        )
        return try Self.parseContent(from: data)
    }

    // MARK: Internal

    /// Extract the first choice's message text. OpenAI guarantees
    /// at least one choice on success; an empty array is treated
    /// as a malformed response so the user sees a useful banner
    /// instead of an empty agent reply. `internal` (rather than
    /// fileprivate) so the response-parsing contract is pinned by
    /// a unit test without going through URLSession.
    static func parseContent(from data: Data) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            let excerpt = String(data: data, encoding: .utf8)?.prefix(300).description ?? "<binary>"
            throw ServerLLMError.malformedResponse("Missing choices[0].message.content. Body: \(excerpt)")
        }
        return content
    }

    // MARK: Private

    private let baseURL: URL
    private let model: String
    private let token: String
    private let temperature: Double
    private let maxTokens: Int?
    private let session: URLSession
}
