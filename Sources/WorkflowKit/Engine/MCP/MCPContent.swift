import Foundation

// MARK: - MCPContent

/// One content block from an MCP `tools/call` reply, modelled as a
/// closed enum over the full set the spec defines. The previous
/// client kept only `text` blocks and returned a bare `String`;
/// that silently dropped everything a server we don't control might
/// send back — images, audio, and (the case we care about most)
/// embedded UI resources like an HTML card rendered after the call.
///
/// Unknown / future block types decode into `.unknown(rawType:)`
/// rather than throwing, so a server that ships a content type newer
/// than this enum degrades to "we saw a block we don't render" instead
/// of failing the whole call. That's the robustness contract: handle
/// the whole known surface, never crash on the unknown part.
public enum MCPContent: Sendable, Equatable {
    /// Plain text — the canonical textual tool output.
    case text(String)
    /// Inline image. `data` is base64; `mimeType` e.g. `image/png`.
    case image(data: String, mimeType: String)
    /// Inline audio. `data` is base64; `mimeType` e.g. `audio/wav`.
    case audio(data: String, mimeType: String)
    /// Embedded resource — the `ui://…` HTML card a tool returns to
    /// be rendered post-call lands here, with the markup in
    /// `resource.text` and `resource.mimeType == "text/html"`.
    case resource(MCPResourceContent)
    /// A link to a resource the client can fetch separately.
    case resourceLink(uri: String, name: String, mimeType: String?)
    /// A content block whose `type` this SDK version doesn't model.
    /// Preserved (rather than dropped) so callers can at least log
    /// or surface that something arrived.
    case unknown(rawType: String)
}

// MARK: - MCPResourceContent

/// Body of an embedded resource block (`EmbeddedResource` in the
/// spec). Exactly one of `text` / `blob` is populated: `text` for
/// textual payloads (HTML, JSON, plain text), `blob` for base64
/// binary. `uri` identifies the resource (`ui://weather/tokyo`,
/// `file://…`, etc.); `mimeType` is how the caller decides whether
/// it can render it.
public struct MCPResourceContent: Sendable, Equatable {
    // MARK: Lifecycle

    public init(uri: String, mimeType: String?, text: String?, blob: String?) {
        self.uri = uri
        self.mimeType = mimeType
        self.text = text
        self.blob = blob
    }

    // MARK: Public

    public let uri: String
    public let mimeType: String?
    public let text: String?
    public let blob: String?

    /// `true` when this resource is HTML the client could render in a
    /// web view — the common "UI resource returned after a tool call"
    /// case the app surfaces in chat.
    public var isHTML: Bool {
        (self.mimeType?.localizedCaseInsensitiveContains("html") ?? false)
    }
}

// MARK: - MCPCallResult

/// Full result of a `tools/call`: every content block plus the
/// server's `isError` flag. `MCPClient.callTool` still returns a
/// plain `String` for back-compat (concatenated text), but
/// `callToolDetailed` returns this so callers can pull out the HTML
/// UI resource — or images, or anything else — instead of having it
/// thrown away inside the client.
public struct MCPCallResult: Sendable, Equatable {
    // MARK: Lifecycle

    public init(content: [MCPContent], isError: Bool) {
        self.content = content
        self.isError = isError
    }

    // MARK: Public

    public let content: [MCPContent]
    public let isError: Bool

    /// Concatenated text from every `.text` block — the same value
    /// the legacy `callTool(...) -> String` returns.
    public var text: String {
        let segments = self.content.compactMap { block -> String? in
            if case let .text(value) = block {
                value
            } else {
                nil
            }
        }
        return segments.joined()
    }

    /// Every embedded resource block, in order. Use this to fetch the
    /// `ui://` HTML card a tool returns after the call.
    public var resources: [MCPResourceContent] {
        self.content.compactMap { block in
            if case let .resource(resource) = block {
                resource
            } else {
                nil
            }
        }
    }

    /// The first embedded resource whose MIME type is HTML, if any —
    /// the convenience the UI layer reaches for to render a card.
    public var firstHTMLResource: MCPResourceContent? {
        self.resources.first(where: \.isHTML)
    }
}
