import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

// MARK: - ServerLLMError

/// Closed set of failure modes the server-LLM HTTP clients
/// surface. Each carries enough context for the Run sheet's
/// error banner to render an actionable message — the user
/// shouldn't have to read Console.app to know what went wrong.
public enum ServerLLMError: LocalizedError, Sendable, Equatable {
    /// `URLSession` returned a non-2xx response. Carries the
    /// status code and a short excerpt of the body so vendor-
    /// specific error shapes (OpenAI's `{"error":{"message":…}}`)
    /// are still readable when surfaced to the user.
    case httpStatus(code: Int, bodyExcerpt: String)
    /// The vendor returned a 2xx but the body didn't decode into
    /// the shape we expected — usually a model id the vendor
    /// doesn't recognise (Gemini surfaces this as 200 + an error
    /// payload, not a 4xx).
    case malformedResponse(String)
    /// Network failure (offline, DNS, timeout). Wraps the
    /// underlying URLError's `localizedDescription` so the user
    /// sees the system message instead of a code.
    case networkFailure(String)
    /// The configured base URL didn't parse as a URL — usually a
    /// typo in the provider editor's override field.
    case invalidBaseURL(String)

    // MARK: Public

    public var errorDescription: String? {
        switch self {
        case let .httpStatus(code, body):
            "Server returned HTTP \(code). \(body)"
        case let .malformedResponse(detail):
            "Couldn't parse the server's reply. \(detail)"
        case let .networkFailure(message):
            "Network error: \(message)"
        case let .invalidBaseURL(raw):
            "The provider's base URL `\(raw)` isn't a valid URL. Fix it in Settings → AI Providers."
        }
    }
}

// MARK: - ServerLLMHTTP

enum ServerLLMHTTP {
    /// Post JSON and return the raw body. Centralises status-code
    /// + transport-error mapping so each vendor client only owns
    /// its request-shaping + response-decoding concerns.
    static func postJSON(
        url: URL,
        body: [String: Any],
        headers: [String: String],
        session: URLSession = .shared
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ServerLLMError.networkFailure(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ServerLLMError.malformedResponse("Non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let excerpt = String(data: data, encoding: .utf8)?.prefix(500).description ?? "<binary>"
            throw ServerLLMError.httpStatus(code: http.statusCode, bodyExcerpt: excerpt)
        }
        return data
    }
}
