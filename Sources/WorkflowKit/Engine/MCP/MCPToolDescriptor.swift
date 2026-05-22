import Foundation

// MARK: - MCPToolDescriptor

/// One tool an MCP server advertised through `tools/list`. The
/// picker UI uses these to populate a chooser so users can pick
/// a tool by name rather than copying it out of vendor docs.
///
/// `inputSchemaJSON` is the server's `inputSchema` payload
/// re-serialised as pretty-printed JSON — kept as a string so
/// callers can preview it verbatim without modeling JSONSchema
/// themselves. `nil` when the server omits a schema.
public struct MCPToolDescriptor: Sendable, Equatable, Identifiable {
    // MARK: Lifecycle

    public init(name: String, description: String?, inputSchemaJSON: String?) {
        self.name = name
        self.description = description
        self.inputSchemaJSON = inputSchemaJSON
    }

    // MARK: Public

    public let name: String
    public let description: String?
    public let inputSchemaJSON: String?

    public var id: String {
        self.name
    }
}
