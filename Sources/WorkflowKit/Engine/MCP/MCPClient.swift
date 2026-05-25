import Aria
import Foundation
import MCP
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

// MARK: - MCPClient

/// MCP (Model Context Protocol) client bound to a single server
/// endpoint. One instance is constructed per call site; the workflow
/// compiler instantiates it per-step rather than pooling, which keeps
/// the engine stateless and matches MCP's session-per-call model for
/// read-mostly tool invocations.
///
/// Backed by the official `modelcontextprotocol/swift-sdk`
/// (`HTTPClientTransport` over Streamable HTTP). We hand-rolled this
/// originally to keep the dep graph tight, but a minimal JSON-only
/// client only worked against servers we configured ourselves: the
/// MCP SDKs (TS, Python, Swift) *default to SSE* responses, so a
/// third-party server we don't control would reply `text/event-stream`
/// and our `JSONSerialization` parse would throw "couldn't be read".
/// The official transport parses both SSE and JSON responses, manages
/// the session, and models every content-block type — that's what
/// "works against arbitrary servers" actually requires. The SDK's
/// `MCP` library only adds swift-system + the small `eventsource`
/// package on top of deps we already carry.
///
/// We run with `streaming: false`: the transport still parses an SSE
/// *response* to our POST (the case that used to break), but does not
/// open a long-lived GET SSE listener — many servers don't support
/// that, and one-shot tool calls don't need server-initiated push.
public struct MCPClient: Sendable {
    // MARK: Lifecycle

    public init(
        serverURL: URL,
        credential: MCPCredential? = nil,
        clientName: String = "Avyra",
        clientVersion: String = "1.0"
    ) {
        self.serverURL = serverURL
        self.credential = credential
        self.clientName = clientName
        self.clientVersion = clientVersion
    }

    // MARK: Public

    /// Invoke `name` with the supplied arguments and return the
    /// concatenated text-content blocks — the canonical textual tool
    /// output, and the back-compatible shape every existing caller
    /// expects. A server-reported error (`isError: true`) re-throws as
    /// `MCPError.serverError` so the engine surfaces tool-side failures
    /// the same way as transport ones.
    ///
    /// Callers that need the embedded UI resource a tool returns after
    /// the call (an HTML card, an image, …) should use
    /// ``callToolDetailed(name:arguments:)`` instead — this method
    /// drops everything that isn't text, by design, to preserve the
    /// old return type.
    public func callTool(
        name: String,
        arguments: [String: JSONValue]
    ) async throws -> String {
        let result = try await self.callToolDetailed(name: name, arguments: arguments)
        if result.isError {
            let detail = result.text.isEmpty ? "<no detail>" : result.text
            throw MCPError.serverError(code: -1, message: detail)
        }
        return result.text
    }

    /// Invoke `name` and return the full result — every content block
    /// (text, image, audio, embedded resource, resource link) plus the
    /// server's `isError` flag. This is the path that surfaces a
    /// `ui://…` HTML resource a tool emits to be rendered post-call:
    /// `result.firstHTMLResource?.text` is the markup.
    ///
    /// Unlike ``callTool(name:arguments:)`` this does *not* throw on
    /// `isError` — the caller inspects `result.isError` and the error
    /// content itself, since an erroring tool may still return a
    /// useful body.
    public func callToolDetailed(
        name: String,
        arguments: [String: JSONValue]
    ) async throws -> MCPCallResult {
        try await self.withConnectedClient { client in
            let (content, isError) = try await client.callTool(
                name: name,
                arguments: Self.toValueMap(arguments)
            )
            return MCPCallResult(
                content: content.map(Self.mapContent),
                isError: isError ?? false
            )
        }
    }

    /// Discover which tools the server exposes. Drains pagination so a
    /// server that returns tools across multiple `nextCursor` pages is
    /// fully enumerated. Returns an empty list when the server
    /// advertises no tools — distinct from a transport failure, which
    /// throws `MCPError`.
    public func listTools() async throws -> [MCPToolDescriptor] {
        try await self.withConnectedClient { client in
            var collected: [MCP.Tool] = []
            var cursor: String?
            repeat {
                let (tools, next) = try await client.listTools(cursor: cursor)
                collected.append(contentsOf: tools)
                cursor = next
            } while cursor != nil
            return collected.map(Self.mapTool)
        }
    }

    // MARK: Private

    private let serverURL: URL
    private let credential: MCPCredential?
    private let clientName: String
    private let clientVersion: String

    private static func makeTransport(
        endpoint: URL,
        credential: MCPCredential?
    ) -> MCP.HTTPClientTransport {
        let authorization = Self.authorizationHeader(for: credential)
        return MCP.HTTPClientTransport(
            endpoint: endpoint,
            streaming: false,
            requestModifier: { request in
                guard let authorization else {
                    return request
                }
                var modified = request
                modified.setValue(authorization, forHTTPHeaderField: "Authorization")
                return modified
            }
        )
    }

    /// Build the `Authorization` header value for a credential.
    /// `bearer` → `Bearer <token>`; `basic` → RFC 7617
    /// `Basic <base64(user:pass)>`.
    private static func authorizationHeader(for credential: MCPCredential?) -> String? {
        switch credential {
        case .none:
            return nil
        case let .bearer(token):
            return "Bearer \(token)"
        case let .basic(username, password):
            let data = Data("\(username):\(password)".utf8)
            return "Basic \(data.base64EncodedString())"
        }
    }

    // MARK: Conversions

    private static func toValueMap(_ values: [String: JSONValue]) -> [String: MCP.Value] {
        values.mapValues(self.toValue)
    }

    /// `JSONValue` → the SDK's `Value`. `JSONValue.integer` is `Int64`;
    /// `Value.int` is `Int` (64-bit on every Apple platform we ship),
    /// so the cast is lossless in practice.
    private static func toValue(_ value: JSONValue) -> MCP.Value {
        switch value {
        case .null:
            .null
        case let .bool(flag):
            .bool(flag)
        case let .integer(number):
            .int(Int(number))
        case let .number(number):
            .double(number)
        case let .string(text):
            .string(text)
        case let .array(items):
            .array(items.map(Self.toValue))
        case let .object(fields):
            .object(fields.mapValues(Self.toValue))
        }
    }

    /// Map one SDK content block to our `MCPContent`. `@unknown
    /// default` keeps us forward-compatible: a block type added in a
    /// future SDK degrades to `.unknown` instead of failing to compile
    /// or — worse — being silently dropped.
    private static func mapContent(_ content: MCP.Tool.Content) -> MCPContent {
        switch content {
        case let .text(text, _, _):
            return .text(text)
        case let .image(data, mimeType, _, _):
            return .image(data: data, mimeType: mimeType)
        case let .audio(data, mimeType, _, _):
            return .audio(data: data, mimeType: mimeType)
        case let .resource(resource, _, _):
            return .resource(MCPResourceContent(
                uri: resource.uri,
                mimeType: resource.mimeType,
                text: resource.text,
                blob: resource.blob
            ))
        case let .resourceLink(uri, name, _, _, mimeType, _):
            return .resourceLink(uri: uri, name: name, mimeType: mimeType)
        @unknown default:
            return .unknown(rawType: "unsupported")
        }
    }

    private static func mapTool(_ tool: MCP.Tool) -> MCPToolDescriptor {
        MCPToolDescriptor(
            name: tool.name,
            description: tool.description,
            inputSchemaJSON: self.schemaJSON(tool.inputSchema)
        )
    }

    /// Re-serialise the tool's input schema (`Value`) to pretty JSON so
    /// callers can preview it / decode it into their own JSONSchema.
    /// A `.null` schema (server omitted one) maps to `nil`, matching
    /// the descriptor's "no schema" contract.
    private static func schemaJSON(_ schema: MCP.Value) -> String? {
        if case .null = schema {
            return nil
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(schema),
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }

    /// Normalise any thrown error into our `MCPError` taxonomy so the
    /// Run sheet renders one consistent set of messages regardless of
    /// whether the failure originated in our code or the SDK.
    private static func mapError(_ error: Error) -> Error {
        if let ours = error as? MCPError {
            return ours
        }
        if let sdk = error as? MCP.MCPError {
            switch sdk {
            case let .transportError(underlying):
                return MCPError.networkFailure(underlying.localizedDescription)
            case .connectionClosed:
                return MCPError.networkFailure("The MCP server closed the connection.")
            case let .serverError(code, message):
                return MCPError.serverError(code: code, message: message)
            case .parseError:
                return MCPError.malformedResponse(sdk.errorDescription ?? "Parse error")
            default:
                return MCPError.serverError(
                    code: sdk.code,
                    message: sdk.errorDescription ?? "MCP protocol error"
                )
            }
        }
        return MCPError.networkFailure(error.localizedDescription)
    }

    /// Stand up a fresh SDK client + transport, run the
    /// initialize handshake, hand the connected client to `body`, then
    /// tear everything down — on both the success and failure paths so
    /// the transport's resources don't leak. SDK errors are normalised
    /// into our `MCPError` so callers see one error taxonomy.
    private func withConnectedClient<T: Sendable>(
        _ body: (MCP.Client) async throws -> T
    ) async throws -> T {
        let client = MCP.Client(name: self.clientName, version: self.clientVersion)
        let transport = Self.makeTransport(
            endpoint: self.serverURL,
            credential: self.credential
        )
        do {
            _ = try await client.connect(transport: transport)
            let result = try await body(client)
            await client.disconnect()
            return result
        } catch {
            await client.disconnect()
            throw Self.mapError(error)
        }
    }
}
