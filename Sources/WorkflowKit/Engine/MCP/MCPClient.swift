import Aria
import Foundation

// MARK: - MCPClient

/// Minimal MCP (Model Context Protocol) client implementing the
/// JSON-RPC 2.0 dance over the Streamable HTTP transport. One
/// instance is bound to a single server endpoint at construction
/// time; the workflow compiler instantiates it per-step rather
/// than pooling, which keeps the engine stateless and matches
/// MCP's session-per-call model for read-mostly tool invocations.
///
/// Why not the official `modelcontextprotocol/swift-sdk`?
/// `WorkflowKit` already keeps a tight dep graph (Aria core +
/// GRDB + tools); pulling in another network-layer SPM tree for
/// the three JSON-RPC methods we need (`initialize`,
/// `notifications/initialized`, `tools/call`) added more surface
/// than we gained. If P1 needs richer transport support — SSE
/// streaming, session resumption, multi-tool batches — the API
/// here is small enough to swap.
public struct MCPClient: Sendable {
    // MARK: Lifecycle

    public init(
        serverURL: URL,
        credential: MCPCredential? = nil,
        session: URLSession = .shared,
        clientName: String = "Avyra",
        clientVersion: String = "1.0"
    ) {
        self.serverURL = serverURL
        self.credential = credential
        self.session = session
        self.clientName = clientName
        self.clientVersion = clientVersion
    }

    // MARK: Public

    /// Invoke `toolName` with the supplied arguments. Performs
    /// the full handshake (`initialize` → `notifications/initialized`
    /// → `tools/call`) on every call. Returns the concatenated
    /// text-content blocks the server replied with — the
    /// canonical MCP shape for textual tool output.
    public func callTool(
        name: String,
        arguments: [String: JSONValue]
    ) async throws -> String {
        let sessionID = try await self.handshake()
        let callPayload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/call",
            "params": [
                "name": name,
                "arguments": Self.toAnyMap(arguments),
            ],
        ]
        let (callData, _) = try await self.postJSON(callPayload, sessionID: sessionID)
        return try Self.parseToolResult(from: callData)
    }

    /// Discover which tools the server exposes. Same handshake
    /// as `callTool`, then POST `tools/list`. The editor's
    /// "Browse tools" affordance uses this so users don't have
    /// to copy a tool name out of vendor docs and risk a typo.
    /// Returns an empty list when the server advertises no
    /// tools — distinct from a transport failure, which throws
    /// `MCPError`.
    public func listTools() async throws -> [MCPToolDescriptor] {
        let sessionID = try await self.handshake()
        let listPayload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/list",
            "params": [String: Any](),
        ]
        let (listData, _) = try await self.postJSON(listPayload, sessionID: sessionID)
        return try Self.parseToolList(from: listData)
    }

    // MARK: Private

    /// MCP protocol version we advertise. Pinned so the client
    /// stays compatible with servers that mid-stream upgrade
    /// their own protocol — we'll bump deliberately if a new
    /// version brings a feature we want.
    private static let protocolVersion = "2025-03-26"

    private let serverURL: URL
    private let credential: MCPCredential?
    private let session: URLSession
    private let clientName: String
    private let clientVersion: String

    /// Throws when the parsed JSON-RPC envelope contains an
    /// `error` field. Successful envelopes (with `result`) pass
    /// through. Bodies with NEITHER are accepted — some servers
    /// reply to notifications with an empty body or a bare 202.
    private static func assertJSONRPCSuccess(in data: Data) throws {
        // 202 Accepted with empty body is a legal MCP response
        // for notifications. Treat empty as success.
        guard !data.isEmpty else {
            return
        }
        let envelope = try Self.decodeEnvelope(from: data)
        if let error = envelope["error"] as? [String: Any] {
            let code = (error["code"] as? Int) ?? -1
            let message = (error["message"] as? String) ?? "<no message>"
            throw MCPError.serverError(code: code, message: message)
        }
    }

    /// Pluck the user-visible text out of a `tools/call` reply.
    /// MCP returns `result.content` as an array of typed blocks;
    /// we concatenate every `text` block so a multi-block reply
    /// (rare but legal) still round-trips a usable string.
    /// `isError: true` re-throws as `MCPError.serverError` so
    /// the engine surfaces tool-side failures the same way as
    /// transport ones.
    private static func parseToolResult(from data: Data) throws -> String {
        let envelope = try Self.decodeEnvelope(from: data)
        if let error = envelope["error"] as? [String: Any] {
            let code = (error["code"] as? Int) ?? -1
            let message = (error["message"] as? String) ?? "<no message>"
            throw MCPError.serverError(code: code, message: message)
        }
        guard let result = envelope["result"] as? [String: Any] else {
            throw MCPError.malformedResponse("Missing `result` in tools/call reply.")
        }
        if result["isError"] as? Bool == true {
            let detail = (result["content"] as? [[String: Any]])?
                .compactMap { $0["text"] as? String }
                .joined(separator: "\n") ?? "<no detail>"
            throw MCPError.serverError(code: -1, message: detail)
        }
        let blocks = (result["content"] as? [[String: Any]]) ?? []
        return blocks.compactMap { block -> String? in
            guard block["type"] as? String == "text" else {
                return nil
            }
            return block["text"] as? String
        }.joined()
    }

    /// Pluck the tools array out of a `tools/list` reply. The
    /// MCP spec says each tool has `name` + optional
    /// `description` + optional `inputSchema`. Schema is kept
    /// as raw JSON so callers can render it without modeling
    /// JSONSchema themselves; if a server omits the schema
    /// entirely, the descriptor's `inputSchemaJSON` is nil.
    private static func parseToolList(from data: Data) throws -> [MCPToolDescriptor] {
        let envelope = try Self.decodeEnvelope(from: data)
        if let error = envelope["error"] as? [String: Any] {
            let code = (error["code"] as? Int) ?? -1
            let message = (error["message"] as? String) ?? "<no message>"
            throw MCPError.serverError(code: code, message: message)
        }
        guard let result = envelope["result"] as? [String: Any] else {
            throw MCPError.malformedResponse("Missing `result` in tools/list reply.")
        }
        let rawTools = (result["tools"] as? [[String: Any]]) ?? []
        return rawTools.compactMap { entry -> MCPToolDescriptor? in
            guard let name = entry["name"] as? String, !name.isEmpty else {
                return nil
            }
            let description = entry["description"] as? String
            var schemaJSON: String?
            if let schema = entry["inputSchema"] as? [String: Any],
               let data = try? JSONSerialization.data(
                   withJSONObject: schema,
                   options: [.prettyPrinted, .sortedKeys]
               ),
               let string = String(data: data, encoding: .utf8) {
                schemaJSON = string
            }
            return MCPToolDescriptor(
                name: name,
                description: description,
                inputSchemaJSON: schemaJSON
            )
        }
    }

    private static func decodeEnvelope(from data: Data) throws -> [String: Any] {
        // Streamable HTTP servers can reply with either a single
        // JSON object or an SSE stream. We only POST tools/call
        // here (which most servers reply to with a single
        // object); SSE responses are rare for one-shot calls.
        // If we see SSE framing, surface a malformed-response
        // error rather than half-parsing it — keeps the
        // implementation honest.
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let excerpt = String(data: data, encoding: .utf8)?
                .prefix(300).description ?? "<binary>"
            throw MCPError.malformedResponse("Reply wasn't a JSON object. Body: \(excerpt)")
        }
        return json
    }

    /// Convert `[String: JSONValue]` to `[String: Any]` for
    /// `JSONSerialization`. Mirrors the arg-template lowering
    /// the workflow compiler does for capability + plugin
    /// steps.
    private static func toAnyMap(_ values: [String: JSONValue]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in values {
            result[key] = self.toAny(value)
        }
        return result
    }

    private static func toAny(_ value: JSONValue) -> Any {
        switch value {
        case let .string(string): string
        case let .integer(integer): integer
        case let .number(number): number
        case let .bool(bool): bool
        case let .array(array): array.map(self.toAny)
        case let .object(object): self.toAnyMap(object)
        case .null: NSNull()
        }
    }

    private static func attachAuth(
        to request: inout URLRequest,
        credential: MCPCredential?
    ) {
        guard let credential else {
            return
        }
        switch credential {
        case let .bearer(token):
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        case let .basic(username, password):
            let pair = "\(username):\(password)"
            guard let data = pair.data(using: .utf8) else {
                return
            }
            let encoded = data.base64EncodedString()
            request.setValue("Basic \(encoded)", forHTTPHeaderField: "Authorization")
        }
    }

    /// Initialize the JSON-RPC session + dispatch the required
    /// `notifications/initialized`. Returns the optional
    /// `Mcp-Session-Id` the server may have stamped on the
    /// initialize response so follow-up requests can pin to
    /// the same session.
    private func handshake() async throws -> String? {
        let initializePayload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "protocolVersion": Self.protocolVersion,
                "capabilities": [String: Any](),
                "clientInfo": [
                    "name": self.clientName,
                    "version": self.clientVersion,
                ],
            ],
        ]
        let (initData, initResponse) = try await self.postJSON(
            initializePayload,
            sessionID: nil
        )
        try Self.assertJSONRPCSuccess(in: initData)
        let sessionID = initResponse.value(forHTTPHeaderField: "Mcp-Session-Id")

        let initialisedPayload: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "notifications/initialized",
            "params": [String: Any](),
        ]
        _ = try await self.postJSON(initialisedPayload, sessionID: sessionID)
        return sessionID
    }

    /// POST a JSON-RPC envelope and return the response body +
    /// the HTTPURLResponse so the caller can pluck headers
    /// (notably `Mcp-Session-Id`). Maps non-2xx + transport
    /// errors into typed `MCPError` cases.
    private func postJSON(
        _ body: [String: Any],
        sessionID: String?
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: self.serverURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let sessionID {
            request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        }
        Self.attachAuth(to: &request, credential: self.credential)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await self.session.data(for: request)
        } catch {
            throw MCPError.networkFailure(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw MCPError.malformedResponse("Non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let excerpt = String(data: data, encoding: .utf8)?
                .prefix(500).description ?? "<binary>"
            throw MCPError.httpStatus(code: http.statusCode, bodyExcerpt: excerpt)
        }
        return (data, http)
    }
}
