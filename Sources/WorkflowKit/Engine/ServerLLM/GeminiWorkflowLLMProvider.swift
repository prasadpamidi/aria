import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

// MARK: - GeminiWorkflowLLMProvider

/// `WorkflowLLMProvider` conformer that POSTs to Google's
/// Gemini `generateContent` endpoint. Gemini puts the API key
/// in the URL query (`?key=…`) rather than a header, and namespaces
/// the request path with the model id (`/models/<model>:generateContent`).
///
/// Stateless; safe to reuse across calls. Streaming variant
/// (`streamGenerateContent`) is not used here — slice 2 sticks to
/// the one-shot endpoint to match the synchronous shape of the
/// other server clients.
public struct GeminiWorkflowLLMProvider: WorkflowLLMProvider {
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
        let url = try Self.requestURL(baseURL: self.baseURL, model: self.model, token: self.token)
        var generationConfig: [String: Any] = ["temperature": self.temperature]
        if let tokens = maxTokens ?? self.maxTokens {
            generationConfig["maxOutputTokens"] = tokens
        }
        let body: [String: Any] = [
            "contents": [[
                "role": "user",
                "parts": [["text": prompt]],
            ]],
            "generationConfig": generationConfig,
        ]
        let data = try await ServerLLMHTTP.postJSON(
            url: url,
            body: body,
            headers: [:],
            session: self.session
        )
        return try Self.parseContent(from: data)
    }

    // MARK: Internal

    /// Pluck the first candidate's text. Gemini sometimes
    /// blocks responses with a `promptFeedback` payload + zero
    /// candidates — that surfaces as a malformed-response error
    /// rather than silently returning an empty string. `internal`
    /// so a unit test can pin the contract without hitting the
    /// network.
    static func parseContent(from data: Data) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let excerpt = String(data: data, encoding: .utf8)?.prefix(300).description ?? "<binary>"
            throw ServerLLMError.malformedResponse("Reply wasn't a JSON object. Body: \(excerpt)")
        }
        guard let candidates = json["candidates"] as? [[String: Any]],
              let first = candidates.first,
              let content = first["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            let feedback = (json["promptFeedback"] as? [String: Any])?["blockReason"] as? String
            let detail = feedback.map { "Blocked: \($0)." } ?? "Missing `candidates[0].content.parts`."
            throw ServerLLMError.malformedResponse(detail)
        }
        let text = parts.compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else {
            throw ServerLLMError.malformedResponse("Reply contained no text parts.")
        }
        return text
    }

    // MARK: Private

    private let baseURL: URL
    private let model: String
    private let token: String
    private let temperature: Double
    private let maxTokens: Int?
    private let session: URLSession

    /// Build `<baseURL>/models/<model>:generateContent?key=<token>`.
    /// Uses `URLComponents` so a non-default base URL with its own
    /// query params still gets the api key appended cleanly.
    private static func requestURL(baseURL: URL, model: String, token: String) throws -> URL {
        let path = baseURL.appendingPathComponent("models/\(model):generateContent")
        guard var components = URLComponents(url: path, resolvingAgainstBaseURL: false) else {
            throw ServerLLMError.invalidBaseURL(baseURL.absoluteString)
        }
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "key", value: token))
        components.queryItems = items
        guard let resolved = components.url else {
            throw ServerLLMError.invalidBaseURL(baseURL.absoluteString)
        }
        return resolved
    }
}
