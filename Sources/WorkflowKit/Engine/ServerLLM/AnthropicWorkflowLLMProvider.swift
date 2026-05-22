import Foundation

// MARK: - AnthropicWorkflowLLMProvider

/// `WorkflowLLMProvider` conformer that POSTs to Anthropic's
/// `/messages` endpoint. Auth uses the `x-api-key` header (NOT
/// Bearer) and the request requires `anthropic-version`. Both are
/// pinned here to a known-good version rather than asking the user
/// to type one — the editor doesn't surface a version field.
///
/// Anthropic requires `max_tokens` on every request; when the user
/// hasn't supplied one (via step or provider config), we fall back
/// to a conservative cap to keep runaway responses from billing
/// surprises.
public struct AnthropicWorkflowLLMProvider: WorkflowLLMProvider {
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
        let url = self.baseURL.appendingPathComponent("messages")
        let resolvedTokens = maxTokens ?? self.maxTokens ?? Self.defaultMaxTokens
        let body: [String: Any] = [
            "model": self.model,
            "messages": [["role": "user", "content": prompt]],
            "max_tokens": resolvedTokens,
            "temperature": self.temperature,
        ]
        let data = try await ServerLLMHTTP.postJSON(
            url: url,
            body: body,
            headers: [
                "x-api-key": self.token,
                "anthropic-version": Self.anthropicVersion,
            ],
            session: self.session
        )
        return try Self.parseContent(from: data)
    }

    // MARK: Internal

    /// Anthropic returns `content` as an array of typed blocks;
    /// for plain text replies it's `[{"type":"text","text":"…"}]`.
    /// We concatenate every text block so multi-block replies
    /// (rare today, more common once Anthropic ships tool-use
    /// blocks) still round-trip a usable string. `internal` so a
    /// unit test can pin the contract without hitting the network.
    static func parseContent(from data: Data) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]] else {
            let excerpt = String(data: data, encoding: .utf8)?.prefix(300).description ?? "<binary>"
            throw ServerLLMError.malformedResponse("Missing `content` array. Body: \(excerpt)")
        }
        let text = content.compactMap { block -> String? in
            guard block["type"] as? String == "text" else {
                return nil
            }
            return block["text"] as? String
        }.joined()
        guard !text.isEmpty else {
            throw ServerLLMError.malformedResponse("Reply contained no text blocks.")
        }
        return text
    }

    // MARK: Private

    /// Pinned API version. Older clients keep working when
    /// Anthropic ships a new one — we'll bump this when a feature
    /// we want (streaming partials, tool use) requires it.
    private static let anthropicVersion = "2023-06-01"
    /// Conservative ceiling when neither step nor provider config
    /// set a max. Picked to cap accidental "summarise the whole
    /// document" bills without truncating typical chat replies.
    private static let defaultMaxTokens = 4096

    private let baseURL: URL
    private let model: String
    private let token: String
    private let temperature: Double
    private let maxTokens: Int?
    private let session: URLSession
}
