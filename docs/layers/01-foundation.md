# Layer 1 — Foundation

The Foundation layer is pure data: value types and enums that flow through the system. No behavior beyond `Codable` conformance and convenience constructors. Zero external dependencies beyond the Swift Standard Library and Foundation.

This layer is the smallest and most important. Get the data model right and every layer above it falls into place.

## Responsibilities

- Define the shape of messages, tool calls, and tool definitions.
- Define the events emitted by providers and the agent loop.
- Define structured types for errors, options, and metadata.
- Provide JSON-shaped types for tool I/O schemas.

## Non-responsibilities

- No protocols defining behavior. Those live in higher layers.
- No IO, no concurrency, no state. Pure values.
- No Apple- or Linux-specific types. Pure Swift.

## Types

### `Message`

The unit of conversation between user, assistant, and tools.

```swift
public struct Message: Codable, Sendable, Equatable {
    public enum Role: String, Codable, Sendable {
        case system
        case user
        case assistant
        case tool
    }

    public let role: Role
    public let content: [ContentPart]
    public let toolCalls: [ToolCall]?       // assistant messages may include tool calls
    public let toolCallId: String?          // tool messages reference the call they answer
    public let metadata: [String: JSONValue]
    public let createdAt: Date

    public init(role: Role, content: [ContentPart], ...)

    // Convenience constructors
    public static func user(_ text: String) -> Message
    public static func system(_ text: String) -> Message
    public static func assistant(_ text: String, toolCalls: [ToolCall]? = nil) -> Message
    public static func tool(callId: String, content: [ContentPart]) -> Message
}
```

**Design notes:**

- Content is always `[ContentPart]`, never a single string. Multimodal content is first-class from day one.
- `metadata` is the one untyped escape hatch — user-supplied keys, JSONValue values.
- `createdAt` is set automatically by the convenience constructors, explicit when constructing manually.

### `ContentPart`

A single piece of message content.

```swift
public enum ContentPart: Codable, Sendable, Equatable {
    case text(String)
    case image(ImageContent)
    case audio(AudioContent)
    case toolUse(ToolCall)              // assistant content may include the tool call inline
    case toolResult(id: String, content: [ContentPart], isError: Bool)
}

public struct ImageContent: Codable, Sendable, Equatable {
    public enum Source: Codable, Sendable {
        case data(Data, mimeType: String)
        case url(URL)
        case identifier(String)         // platform-managed reference (e.g., PHAsset id)
    }
    public let source: Source
    public let detail: Detail?
    public enum Detail: String, Codable, Sendable { case low, high, auto }
}

public struct AudioContent: Codable, Sendable, Equatable {
    public let source: ImageContent.Source       // same shape, reused
    public let duration: TimeInterval?
}
```

**Design notes:**

- `Source.identifier` is the platform-agnostic way to reference asset library items without forcing `PHAsset` (or Android equivalent) into core types. The Apple module can expand identifiers into `Data`.
- Tool results are content parts so they can be embedded in assistant messages or stand alone — matching modern provider APIs.

### `ToolCall` and `ToolDefinition`

```swift
public struct ToolCall: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let arguments: JSONValue
}

public struct ToolDefinition: Codable, Sendable, Equatable {
    public let name: String
    public let description: String
    public let inputSchema: JSONSchema
    public let outputSchema: JSONSchema?    // optional; many providers don't use it
}
```

`ToolCall` is the request from the model. `ToolDefinition` is what we tell the model is available. The runtime `Tool` protocol (Layer 3) produces `ToolDefinition` for the model and accepts `ToolCall` arguments to execute.

### `ProviderEvent`

What an `LLMProvider` emits while streaming.

```swift
public enum ProviderEvent: Sendable {
    case messageStart(messageId: String)
    case textDelta(String)
    case toolCallStart(ToolCall)
    case toolCallDelta(id: String, argumentsDelta: String)
    case toolCallEnd(id: String)
    case messageStop(FinishReason)
    case usage(TokenUsage)
}

public enum FinishReason: String, Codable, Sendable {
    case endTurn          // model is done
    case maxTokens        // hit token limit
    case toolUse          // model wants to call tools
    case stopSequence     // hit a stop string
    case refusal          // model refused
    case error            // provider error
}

public struct TokenUsage: Codable, Sendable, Equatable {
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheReadTokens: Int?
    public let cacheCreationTokens: Int?
}
```

**Design notes:**

- Tool calls stream incrementally (`toolCallStart` → `toolCallDelta`* → `toolCallEnd`) to support providers that emit JSON arguments token-by-token.
- `TokenUsage` exists in core because it's universal; cost calculation is *not* in core (it's pricing-specific).

### `AgentEvent`

What the `Agent` emits. Distinct from `ProviderEvent` because the agent loop adds higher-level semantics.

```swift
public enum AgentEvent: Sendable {
    case userMessageReceived(Message)
    case stepStart(Int)
    case assistantStart
    case textDelta(String)
    case toolCallRequested(ToolCall)
    case toolExecutionStart(callId: String)
    case toolExecutionEnd(callId: String, result: ToolExecutionResult)
    case stepEnd(Int)
    case finish(FinishReason)
    case error(AgentError)
}

public struct ToolExecutionResult: Sendable {
    public let output: JSONValue
    public let isError: Bool
    public let duration: Duration
}
```

**Design notes:**

- `AgentEvent` does not reference `ProviderEvent`. The agent translates one to the other (see [05-agent.md](05-agent.md)).
- The agent emits both fine-grained (`textDelta`) and coarse-grained (`stepEnd`) events so consumers can render at any granularity.

### `JSONSchema` and `JSONValue`

```swift
public indirect enum JSONSchema: Codable, Sendable, Equatable {
    case string(description: String? = nil, enumValues: [String]? = nil)
    case number(description: String? = nil)
    case integer(description: String? = nil)
    case boolean(description: String? = nil)
    case array(items: JSONSchema, description: String? = nil)
    case object(
        properties: [String: JSONSchema],
        required: [String] = [],
        description: String? = nil
    )
    case oneOf([JSONSchema])
    case anyOf([JSONSchema])
    case allOf([JSONSchema])
    case null

    public func jsonSchemaDictionary() -> [String: Any]   // standard JSON Schema rendering
}

public indirect enum JSONValue: Codable, Sendable, Equatable, Hashable {
    case null
    case bool(Bool)
    case integer(Int)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}
```

**Design notes:**

- `JSONSchema` is structured, not a `[String: Any]`. Type-safe construction, type-safe consumption.
- `JSONValue` is the universal exchange format for tool arguments and tool results. `Codable` types convert via `JSONValue.encode(_:)` and `JSONValue.decode(_:_:)`.

### `AgentError`

```swift
public enum AgentError: Error, Sendable {
    case providerFailed(String, underlying: Error?)
    case toolNotFound(String)
    case toolExecutionFailed(toolName: String, underlying: Error)
    case maxStepsReached(Int)
    case invalidToolArguments(toolName: String, reason: String)
    case cancelled
    case timeout(Duration)
    case malformedProviderEvent(String)
    case configurationInvalid(String)
}
```

All errors are values. No `NSError`, no string-throws, no `Error & CustomStringConvertible` tricks.

### `RunOptions`

Threaded through every `Runnable` invocation.

```swift
public struct RunOptions: Sendable {
    public var runId: UUID
    public var parentRunId: UUID?
    public var tags: [String]
    public var metadata: [String: JSONValue]
    public var observers: [any Observer]
    public var deadline: ContinuousClock.Instant?
    public var cancellation: CancellationToken?

    public init(...)
}
```

**Design notes:**

- `runId` is generated automatically; `parentRunId` lets you trace nested runs.
- `observers` are passed by reference (existential), allowing external systems to attach.
- `deadline` is a deadline, not a duration — composable through `pipe`.

### `CancellationToken`

A simple cooperative cancellation token. (Swift's `Task.isCancelled` works for the common case; this is for cases where you need to share cancellation across multiple tasks.)

```swift
public final class CancellationToken: @unchecked Sendable {
    public var isCancelled: Bool { get }
    public func cancel()
    public func onCancel(_ handler: @Sendable @escaping () -> Void)
}
```

`@unchecked Sendable` because it uses internal locking; this is the one place we pay that cost intentionally.

## What this layer does NOT include

- `Runnable` (Layer 2)
- `LLMProvider`, `Tool`, `Embedder` (Layer 3)
- `ChatHistory`, `Checkpointer`, `VectorStore` (Layer 4)
- `Agent`, `AgentMiddleware`, `AgentConfig` (Layer 5)
- `StateGraph` (Layer 6)
- Any actor, any IO, any platform-specific type.

## Testing

The Foundation layer is tested with simple value tests:

- Round-trip `Codable`: encode → decode → equal.
- Equality and hashability of all types.
- `JSONSchema` rendering matches the JSON Schema specification.
- `JSONValue` round-trips through `JSONEncoder`/`JSONDecoder`.

These tests run on Linux without modification.

## Future considerations

- **Streaming usage events.** Providers that emit incremental usage data (tokens-so-far) might motivate adding `case usageDelta(TokenUsage)` to `ProviderEvent`. Defer until a real provider needs it.
- **Structured refusal.** `FinishReason.refusal` is a flag. If providers start emitting structured refusal data (categories, severity), introduce a `Refusal` struct and migrate.
- **Schema validation.** Today `JSONSchema` describes shapes but doesn't validate. A `JSONSchemaValidator` could live in this layer if needed; defer until a concrete need exists.
