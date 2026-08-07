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
        outputSchema: JSONSchema? = nil,
        promptGuidance: String? = nil
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.outputSchema = outputSchema
        self.promptGuidance = promptGuidance
    }

    // MARK: Public

    public let name: String
    public let description: String
    public let inputSchema: JSONSchema
    public let outputSchema: JSONSchema?

    /// Usage policy for this tool, emitted into the system prompt by
    /// `ContextAssembler` — and only when the tool survived selection.
    ///
    /// Guidance belongs to the tool rather than to a hand-written
    /// prompt because the two drift apart otherwise. Policy written
    /// into an app's system prompt outlives the tool it describes: turn
    /// the tool off and the model is still instructed at length on when
    /// to call something it no longer has. Attaching guidance here
    /// makes that state unrepresentable, and stops unselected tools
    /// from spending tokens on instructions for capabilities the model
    /// was never given.
    ///
    /// Prefer short, positive, imperative phrasing. Dense negation
    /// ("ONLY", "do NOT", "never") is what small models follow worst,
    /// and long policy blocks are prone to being reproduced as output
    /// rather than obeyed.
    public let promptGuidance: String?
}
