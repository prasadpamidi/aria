import Aria
import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

// MARK: - HTTPTool

/// Cross-platform tool that performs HTTP requests. The model passes
/// a URL, optional method/headers/body; the tool returns the status
/// code, response headers, and response body (text — non-text
/// responses surface their byte count instead so the model isn't fed
/// binary garbage).
///
/// **Why an HTTPClient is injected** rather than hardcoded
/// `URLSession.shared`: tests need to short-circuit network I/O, and
/// hosted apps may want to route through their own auth-aware
/// session. Default consumers can pass `.shared` and ignore the
/// indirection.
///
/// **Safety**: the tool is intentionally low-level — no allowlist,
/// no header sanitization. Apps that need to constrain what models
/// can fetch should wrap or substitute this tool, not expand it.
public struct HTTPTool: Tool {
    // MARK: Lifecycle

    public init(client: HTTPClient = URLSessionHTTPClient()) {
        self.client = client
    }

    // MARK: Public

    public struct Input: Codable, Sendable {
        // MARK: Lifecycle

        public init(
            url: String,
            method: String? = nil,
            headers: [String: String]? = nil,
            body: String? = nil
        ) {
            self.url = url
            self.method = method
            self.headers = headers
            self.body = body
        }

        // MARK: Public

        public let url: String
        public let method: String?
        public let headers: [String: String]?
        public let body: String?
    }

    public struct Output: Codable, Sendable {
        // MARK: Lifecycle

        public init(status: Int, headers: [String: String], body: String, isBinary: Bool) {
            self.status = status
            self.headers = headers
            self.body = body
            self.isBinary = isBinary
        }

        // MARK: Public

        public let status: Int
        public let headers: [String: String]
        public let body: String
        /// Set when the response wasn't decodable as UTF-8 text. The
        /// `body` field carries `"<binary: N bytes>"` in that case so
        /// the model has a non-garbage placeholder.
        public let isBinary: Bool
    }

    public static let name = "http_request"
    public static let description = """
    Perform an HTTP request and return status, headers, and a UTF-8 body.

    Use this when you need to look up live data — weather, news, prices, \
    public APIs. Prefer GET; only use POST/PUT/DELETE when the user \
    explicitly asks to modify something on a remote service.
    """

    public static var inputSchema: JSONSchema {
        .object(
            properties: [
                "url": .string(description: "Absolute URL to request, e.g. https://api.example.com/v1/thing"),
                "method": .string(
                    description: "HTTP method. Defaults to GET when omitted.",
                    enumValues: ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD"]
                ),
                "headers": .object(
                    properties: [:],
                    description: "Request headers as a string-to-string map.",
                    additionalProperties: true
                ),
                "body": .string(description: "Request body, UTF-8 text. Omit for GET/HEAD."),
            ],
            required: ["url"]
        )
    }

    public func call(_ input: Input, context _: ToolContext) async throws -> Output {
        guard let url = URL(string: input.url) else {
            throw HTTPToolError.invalidURL(input.url)
        }
        var request = URLRequest(url: url)
        request.httpMethod = (input.method ?? "GET").uppercased()
        for (key, value) in input.headers ?? [:] {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let body = input.body, !body.isEmpty {
            request.httpBody = Data(body.utf8)
        }
        let (data, response) = try await self.client.perform(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let headers = Self.headerMap(from: response)
        if let text = String(data: data, encoding: .utf8) {
            return Output(status: status, headers: headers, body: text, isBinary: false)
        }
        return Output(
            status: status,
            headers: headers,
            body: "<binary: \(data.count) bytes>",
            isBinary: true
        )
    }

    // MARK: Private

    private let client: any HTTPClient

    private static func headerMap(from response: URLResponse) -> [String: String] {
        guard let http = response as? HTTPURLResponse else {
            return [:]
        }
        var result: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let keyStr = key as? String, let valueStr = value as? String {
                result[keyStr] = valueStr
            }
        }
        return result
    }
}

// MARK: - HTTPClient

/// Minimal protocol so tests + custom-session consumers can swap the
/// network transport without touching the tool body. Default impl is
/// `URLSessionHTTPClient` over `URLSession.shared`.
public protocol HTTPClient: Sendable {
    func perform(_ request: URLRequest) async throws -> (Data, URLResponse)
}

// MARK: - URLSessionHTTPClient

public struct URLSessionHTTPClient: HTTPClient {
    // MARK: Lifecycle

    public init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: Public

    public func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await self.session.data(for: request)
    }

    // MARK: Private

    private let session: URLSession
}

// MARK: - HTTPToolError

public enum HTTPToolError: LocalizedError {
    case invalidURL(String)

    // MARK: Public

    public var errorDescription: String? {
        switch self {
        case let .invalidURL(raw):
            "Invalid URL: \"\(raw)\""
        }
    }
}
