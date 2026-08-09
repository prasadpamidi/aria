import Aria
import Foundation
import MCP
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

// MARK: - MCPClient

/// MCP (Model Context Protocol) client bound to a single server
/// endpoint. Instances stay cheap to construct — the value is a handle,
/// and the underlying connection lives in `MCPSessionPool` keyed by
/// endpoint + credential, so constructing one per call site costs
/// nothing and reuses the live session.
///
/// It previously connected and ran a full `initialize` handshake per
/// call, on the stated grounds that this "matches MCP's session-per-call
/// model". MCP has no such model — it is a stateful session protocol,
/// and Streamable HTTP carries an `Mcp-Session-Id` across the session.
/// See `MCPSessionPool` for what that cost.
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

    /// - Parameter clientName: How this app introduces itself in the
    ///   MCP handshake. Defaults to the host bundle's name rather than a
    ///   literal, which is how every Niora request came to identify
    ///   itself as "Avyra" — the default was hardcoded in a shared
    ///   package and no call site overrode it.
    public init(
        serverURL: URL,
        credential: MCPCredential? = nil,
        clientName: String = MCPClient.defaultClientName,
        clientVersion: String = "1.0"
    ) {
        self.serverURL = serverURL
        self.credential = credential
        self.clientName = clientName
        self.clientVersion = clientVersion
        self.transportFactory = nil
    }

    /// Test seam: supply the transport instead of building an
    /// `HTTPClientTransport` from the endpoint.
    ///
    /// Without this the mapping code below — pagination draining,
    /// content-block conversion, prompt argument flattening — can only
    /// be exercised against a live third-party server, which is to say
    /// never in CI.
    init(
        serverURL: URL,
        credential: MCPCredential?,
        clientName: String,
        clientVersion: String,
        transportFactory: @escaping @Sendable () -> any Transport
    ) {
        self.serverURL = serverURL
        self.credential = credential
        self.clientName = clientName
        self.clientVersion = clientVersion
        self.transportFactory = transportFactory
    }

    // MARK: Public

    /// The host app's name, or a neutral fallback off-app (tests, CLI).
    public static let defaultClientName: String = {
        let keys = ["CFBundleDisplayName", "CFBundleName"]
        for key in keys {
            if let name = Bundle.main.object(forInfoDictionaryKey: key) as? String,
               !name.isEmpty {
                return name
            }
        }
        return "aria-mcp-client"
    }()

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

    /// Enumerate the server's resources, draining pagination.
    ///
    /// Distinct from tools: a tool is something the model *calls*, a
    /// resource is content the host can read or render. MCP Apps
    /// arrive here — a `ui://` resource with a
    /// `text/html;profile=mcp-app` MIME type is an interactive surface
    /// rather than data.
    public func listResources() async throws -> [MCPResourceDescriptor] {
        try await self.withConnectedClient { client in
            var collected: [MCP.Resource] = []
            var cursor: String?
            repeat {
                let (resources, next) = try await client.listResources(cursor: cursor)
                collected.append(contentsOf: resources)
                cursor = next
            } while cursor != nil
            return collected.map {
                MCPResourceDescriptor(
                    uri: $0.uri,
                    name: $0.name,
                    description: $0.description,
                    mimeType: $0.mimeType,
                    size: $0.size
                )
            }
        }
    }

    /// Read one resource by URI.
    ///
    /// Returns every content block the server sends. A resource may be
    /// text, base64 `blob`, or several parts — callers wanting the
    /// markup of a UI resource want `firstHTMLResource`.
    public func readResource(uri: String) async throws -> MCPCallResult {
        try await self.withConnectedClient { client in
            let contents = try await client.readResource(uri: uri)
            return MCPCallResult(
                content: contents.map { content in
                    if let text = content.text {
                        return .resource(MCPResourceContent(
                            uri: content.uri,
                            mimeType: content.mimeType,
                            text: text,
                            blob: nil
                        ))
                    }
                    return .resource(MCPResourceContent(
                        uri: content.uri,
                        mimeType: content.mimeType,
                        text: nil,
                        blob: content.blob
                    ))
                },
                isError: false
            )
        }
    }

    /// Enumerate the server's prompt templates, draining pagination.
    public func listPrompts() async throws -> [MCPPromptDescriptor] {
        try await self.withConnectedClient { client in
            var collected: [MCP.Prompt] = []
            var cursor: String?
            repeat {
                let (prompts, next) = try await client.listPrompts(cursor: cursor)
                collected.append(contentsOf: prompts)
                cursor = next
            } while cursor != nil
            return collected.map { prompt in
                MCPPromptDescriptor(
                    name: prompt.name,
                    description: prompt.description,
                    arguments: (prompt.arguments ?? []).map {
                        MCPPromptDescriptor.Argument(
                            name: $0.name,
                            description: $0.description,
                            required: $0.required ?? false
                        )
                    }
                )
            }
        }
    }

    // MARK: Private

    private let serverURL: URL
    private let credential: MCPCredential?
    private let clientName: String
    private let clientVersion: String
    private let transportFactory: (@Sendable () -> any Transport)?

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

    /// Distinguishes credentials without putting secrets in a
    /// dictionary key. Collisions only cost a needless reconnect.
    private static func fingerprint(_ credential: MCPCredential?) -> Int {
        var hasher = Hasher()
        switch credential {
        case .none:
            hasher.combine(0)
        case let .bearer(token):
            hasher.combine(1)
            hasher.combine(token)
        case let .basic(username, password):
            hasher.combine(2)
            hasher.combine(username)
            hasher.combine(password)
        }
        return hasher.finalize()
    }

    /// Run `body` against a pooled, connected client. SDK errors are
    /// normalised into our `MCPError` so callers see one taxonomy
    /// regardless of whether the failure came from our code or the SDK.
    ///
    /// The session is *not* torn down afterwards — that is the point.
    /// `MCPSessionPool` owns its lifetime, reuses it for the next call,
    /// and evicts it once idle.
    private func withConnectedClient<T: Sendable>(
        _ body: @Sendable @escaping (MCP.Client) async throws -> T
    ) async throws -> T {
        let endpoint = self.serverURL
        let credential = self.credential
        let override = self.transportFactory
        do {
            return try await MCPSessionPool.shared.withClient(
                key: MCPSessionKey(
                    endpoint: endpoint,
                    credentialFingerprint: Self.fingerprint(credential),
                    clientName: self.clientName,
                    clientVersion: self.clientVersion
                ),
                makeTransport: {
                    override?() ?? Self.makeTransport(endpoint: endpoint, credential: credential)
                },
                body: body
            )
        } catch {
            throw Self.mapError(error)
        }
    }
}
