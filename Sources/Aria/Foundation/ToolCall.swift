import Foundation

// MARK: - ToolCall

/// A request from the model to invoke a tool.
///
/// Identified by `id`, which the agent loop uses to correlate the call
/// with its eventual `tool` message containing the result.
public struct ToolCall: Sendable, Equatable, Codable {
    // MARK: Lifecycle

    public init(id: String, name: String, arguments: JSONValue) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }

    // MARK: Public

    public let id: String
    public let name: String
    public let arguments: JSONValue
}

// MARK: - ToolDefinition

/// The serializable description of a tool sent to the model.
///
/// Tools advertise themselves to providers via `ToolDefinition` so the
/// model can decide when and how to invoke them.
public struct ToolDefinition: Sendable, Equatable, Codable {
    // MARK: Lifecycle

    public init(
        name: String,
        description: String,
        inputSchema: JSONSchema,
        outputSchema: JSONSchema? = nil
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.outputSchema = outputSchema
    }

    // MARK: Public

    public let name: String
    public let description: String
    public let inputSchema: JSONSchema
    public let outputSchema: JSONSchema?
}
