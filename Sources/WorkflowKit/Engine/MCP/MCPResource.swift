import Foundation

// MARK: - MCPResourceDescriptor

/// A resource a server advertises, as returned by `resources/list`.
///
/// Mirrors `MCPToolDescriptor`: a plain value with no SDK types in it,
/// so persistence and UI never import `MCP`.
public struct MCPResourceDescriptor: Codable, Hashable, Sendable, Identifiable {
    // MARK: Lifecycle

    public init(
        uri: String,
        name: String,
        description: String? = nil,
        mimeType: String? = nil,
        size: Int? = nil
    ) {
        self.uri = uri
        self.name = name
        self.description = description
        self.mimeType = mimeType
        self.size = size
    }

    // MARK: Public

    public let uri: String
    public let name: String
    public let description: String?
    public let mimeType: String?
    public let size: Int?

    public var id: String {
        self.uri
    }

    /// Whether this resource is an interactive UI surface rather than
    /// data to read.
    ///
    /// [MCP Apps](https://blog.modelcontextprotocol.io/posts/2025-11-21-mcp-apps/)
    /// marks these with a `ui://` URI and the
    /// `text/html;profile=mcp-app` MIME type. The profile parameter is
    /// what distinguishes an interactive app from a server that merely
    /// serves HTML, so both halves are checked — a bare `text/html`
    /// resource is a document, and rendering it as an app would grant
    /// it a message channel it never asked for.
    public var isInteractiveUI: Bool {
        guard self.uri.hasPrefix("ui://") else {
            return false
        }
        guard let mimeType else {
            return false
        }
        return mimeType.replacingOccurrences(of: " ", with: "")
            .lowercased()
            .contains("profile=mcp-app")
    }
}

// MARK: - MCPPromptDescriptor

/// A prompt template a server advertises.
///
/// Prompts are the surface Discover recipes map onto: a named, described
/// entry point with typed arguments, which is exactly the shape a
/// recipe needs.
public struct MCPPromptDescriptor: Codable, Hashable, Sendable, Identifiable {
    // MARK: Lifecycle

    public init(name: String, description: String? = nil, arguments: [Argument] = []) {
        self.name = name
        self.description = description
        self.arguments = arguments
    }

    // MARK: Public

    public struct Argument: Codable, Hashable, Sendable {
        // MARK: Lifecycle

        public init(name: String, description: String? = nil, required: Bool = false) {
            self.name = name
            self.description = description
            self.required = required
        }

        // MARK: Public

        public let name: String
        public let description: String?
        public let required: Bool
    }

    public let name: String
    public let description: String?
    public let arguments: [Argument]

    public var id: String {
        self.name
    }
}
