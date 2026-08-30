import Foundation

// MARK: - Tool

/// A tool the model can invoke during a run.
///
/// `Tool` is a protocol with associated `Input` and `Output` types so
/// the compiler enforces the shapes a tool sends and receives. Use
/// `AnyTool` to put heterogeneous tools into a collection.
///
/// Conforming types implement `call(_:context:)` with a `Codable` input
/// and output. The runtime decodes the model's tool call arguments into
/// `Input`, runs `call`, and re-encodes the result.
public protocol Tool: Sendable {
    associatedtype Input: Codable & Sendable
    associatedtype Output: Codable & Sendable

    /// The name the model will use to refer to this tool.
    static var name: String { get }

    /// A natural-language description of what the tool does.
    static var description: String { get }

    /// JSON Schema describing the tool's input shape.
    static var inputSchema: JSONSchema { get }

    /// Optional JSON Schema describing the tool's output shape.
    static var outputSchema: JSONSchema? { get }

    /// Optional usage policy, surfaced into the system prompt by
    /// `ContextAssembler` — and only when this tool is actually sent.
    ///
    /// Declare policy here rather than writing it into the app's system
    /// prompt. Prompt-side policy outlives the tool it describes:
    /// disable the tool and the model is still instructed at length on
    /// when to call something it no longer has. Declared here, the two
    /// cannot drift apart, and a tool that loses tool selection costs
    /// nothing in instructions either.
    ///
    /// Prefer short, positive, imperative phrasing.
    static var promptGuidance: String? { get }

    /// Execute the tool. Return the typed output, or throw to surface a
    /// failure as a tool error to the model.
    func call(_ input: Input, context: ToolContext) async throws -> Output
}

extension Tool {
    public static var outputSchema: JSONSchema? {
        nil
    }

    public static var promptGuidance: String? {
        nil
    }

    /// The serializable description of this tool.
    public static var definition: ToolDefinition {
        ToolDefinition(
            name: self.name,
            description: self.description,
            inputSchema: self.inputSchema,
            outputSchema: self.outputSchema,
            promptGuidance: self.promptGuidance
        )
    }
}

// MARK: - ToolContext

/// Per-call context passed to a tool's `call` method.
///
/// Intentionally minimal. Tools that need additional dependencies (an
/// HTTP client, a database actor) take them through `init` rather than
/// via `ToolContext`.
public struct ToolContext: Sendable {
    // MARK: Lifecycle

    public init(runId: UUID = UUID(), metadata: [String: JSONValue] = [:]) {
        self.runId = runId
        self.metadata = metadata
    }

    // MARK: Public

    public let runId: UUID
    public let metadata: [String: JSONValue]
}

// MARK: - AnyTool

/// A type-erased `Tool`, suitable for putting in a homogeneous collection
/// (e.g., `AgentConfig.tools: [AnyTool]`).
///
/// `AnyTool` lifts the typed tool's `call` behind a closure that accepts
/// and returns `JSONValue`. Decoding into the tool's `Input` and encoding
/// from the tool's `Output` happens transparently.
public struct AnyTool: Sendable {
    // MARK: Lifecycle

    public init<T: Tool>(_ tool: T) {
        self.definition = T.definition
        self.invoke = { arguments, context in
            let input: T.Input
            do {
                input = try arguments.decode(T.Input.self)
            } catch {
                throw AgentError.invalidToolArguments(
                    toolName: T.name,
                    reason: String(describing: error)
                )
            }
            do {
                let output = try await tool.call(input, context: context)
                return try JSONValue.encode(output)
            } catch let error as AgentError {
                throw error
            } catch {
                throw AgentError.toolExecutionFailed(
                    toolName: T.name,
                    underlying: ErrorBox(error)
                )
            }
        }
    }

    /// Construct an `AnyTool` from a closure rather than a `Tool`-conforming
    /// type. Useful for ad-hoc tools that do not warrant their own type.
    public init(
        definition: ToolDefinition,
        invoke: @Sendable @escaping (JSONValue, ToolContext) async throws -> JSONValue
    ) {
        self.definition = definition
        self.invoke = invoke
    }

    // MARK: Public

    public let definition: ToolDefinition
    public let invoke: @Sendable (JSONValue, ToolContext) async throws -> JSONValue

    /// The same tool, advertised differently.
    ///
    /// Used to send a compacted schema while keeping the original
    /// invocation. What the model is *told* about a tool and what
    /// happens when it calls one are separate concerns, and this is the
    /// seam between them — the closure is untouched, so a compacted
    /// definition cannot change behaviour, only description.
    public func replacingDefinition(_ definition: ToolDefinition) -> AnyTool {
        AnyTool(definition: definition, invoke: self.invoke)
    }
}

extension AnyTool {
    /// Convenience accessor: the tool's name as advertised to the model.
    public var name: String {
        self.definition.name
    }
}
