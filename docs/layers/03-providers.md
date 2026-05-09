# Layer 3 — Providers

This layer defines the boundary between Aria's core orchestration and the actual model and tool implementations. It contains four protocols: `LLMProvider`, `Tool`, `Embedder`, and `Tokenizer`.

These are **protocols only** in `Aria`. Concrete implementations live in `AriaApple` (FoundationModels, MLX, Core ML, NLEmbedding) or in user code.

## `LLMProvider`

The model boundary.

```swift
public protocol LLMProvider: Sendable {
    var capabilities: ProviderCapabilities { get }

    func stream(
        messages: [Message],
        tools: [ToolDefinition],
        options: GenerationOptions
    ) -> AsyncThrowingStream<ProviderEvent, Error>
}

public struct ProviderCapabilities: Sendable, Codable {
    public let supportsStreaming: Bool
    public let supportsToolUse: Bool
    public let supportsParallelToolCalls: Bool
    public let supportsVision: Bool
    public let supportsAudio: Bool
    public let supportsStructuredOutput: Bool
    public let supportsSystemPrompt: Bool
    public let maxContextTokens: Int?
    public let modelIdentifier: String
}

public struct GenerationOptions: Sendable {
    public var temperature: Double?
    public var topP: Double?
    public var topK: Int?
    public var maxTokens: Int?
    public var stopSequences: [String]
    public var responseFormat: ResponseFormat?
    public var seed: UInt64?
    public var providerSpecific: [String: JSONValue]
}

public enum ResponseFormat: Sendable {
    case text
    case json
    case schema(JSONSchema)
}
```

### Why streaming-only

The protocol exposes only `stream(...)`. Non-streaming consumption is achieved by collecting the stream:

```swift
let allEvents = try await Array(provider.stream(messages: msgs, tools: [], options: .init()))
```

One code path for both modes. Providers that don't natively stream emit a single `messageStop` event.

### `ProviderCapabilities`

The agent layer reads capabilities to adapt behavior:

- If `supportsToolUse` is `false`, the agent emits a structured-prompt fallback that asks the model to produce JSON tool calls in text.
- If `supportsParallelToolCalls` is `false`, the agent serializes tool execution.
- If `supportsStructuredOutput` is `false` and the user requests JSON output, the agent post-processes text into JSON.

Capabilities are static for a given provider instance — they don't change per request.

### `GenerationOptions.providerSpecific`

The escape hatch for provider-specific knobs (e.g., FoundationModels' tool-choice mode, MLX's repetition penalty). Untyped `JSONValue` here is intentional: typing every provider's quirks would explode core surface.

## `Tool`

The function-calling boundary.

```swift
public protocol Tool: Sendable {
    associatedtype Input: Codable & Sendable
    associatedtype Output: Codable & Sendable

    static var name: String { get }
    static var description: String { get }
    static var inputSchema: JSONSchema { get }
    static var outputSchema: JSONSchema? { get }

    func call(_ input: Input, context: ToolContext) async throws -> Output
}

extension Tool {
    public static var outputSchema: JSONSchema? { nil }     // optional default

    public static var definition: ToolDefinition {
        ToolDefinition(
            name: name,
            description: description,
            inputSchema: inputSchema,
            outputSchema: outputSchema
        )
    }
}
```

### Why associated types

Type-safe input and output. The compiler enforces that `Calculator.Input` is `CalculatorInput`, not `Any`. Tools cannot accidentally produce the wrong shape.

### `ToolContext`

```swift
public struct ToolContext: Sendable {
    public let runId: UUID
    public let cancellationToken: CancellationToken
    public let metadata: [String: JSONValue]
}
```

Intentionally minimal. Tools that need additional context (an HTTP client, a database connection) take those as `init` parameters, not via `ToolContext`.

### Type erasure

`Tool` has associated types, so collections need `AnyTool`:

```swift
public struct AnyTool: Sendable {
    public let definition: ToolDefinition
    public let execute: @Sendable (JSONValue, ToolContext) async throws -> JSONValue

    public init<T: Tool>(_ tool: T) {
        self.definition = T.definition
        self.execute = { args, ctx in
            let typedInput = try JSONDecoder().decode(T.Input.self, from: try args.encoded())
            let output = try await tool.call(typedInput, context: ctx)
            return try JSONValue.encode(output)
        }
    }
}
```

`AgentConfig.tools: [AnyTool]` — that's how tools are passed to the agent.

### Example tool

```swift
struct WeatherTool: Tool {
    struct Input: Codable, Sendable {
        let city: String
        let units: Units
        enum Units: String, Codable, Sendable { case metric, imperial }
    }

    struct Output: Codable, Sendable {
        let temperature: Double
        let condition: String
    }

    static var name = "get_weather"
    static var description = "Get current weather for a city"
    static var inputSchema: JSONSchema {
        .object(properties: [
            "city": .string(description: "City name"),
            "units": .string(description: "Units", enumValues: ["metric", "imperial"])
        ], required: ["city", "units"])
    }

    let httpClient: HTTPClient

    func call(_ input: Input, context: ToolContext) async throws -> Output {
        // ...
    }
}
```

## `Embedder`

```swift
public protocol Embedder: Sendable {
    var dimensions: Int { get }
    var maxInputLength: Int { get }
    var modelIdentifier: String { get }

    func embed(_ texts: [String]) async throws -> [[Float]]
    func embed(_ text: String) async throws -> [Float]
}

extension Embedder {
    public func embed(_ text: String) async throws -> [Float] {
        let result = try await embed([text])
        guard let vector = result.first else {
            throw AgentError.providerFailed("embedder returned no vectors", underlying: nil)
        }
        return vector
    }
}
```

### Design notes

- Batch is the primary API; single-text is a default convenience. Most embedders benefit from batching.
- Vectors are `[Float]`, not `[Double]`. Embeddings rarely need 64-bit precision; `Float` halves memory.
- `dimensions` is required so consumers (e.g., `VectorStore`) can validate before storing.
- `maxInputLength` is in characters, not tokens, to avoid coupling to a specific tokenizer. Embedders that have a token limit truncate or chunk internally.

## `Tokenizer`

```swift
public protocol Tokenizer: Sendable {
    var modelIdentifier: String { get }

    func count(_ text: String) async throws -> Int
    func count(_ messages: [Message]) async throws -> Int
}
```

Used by `HistoryPolicy.tokenWindow` and any other component that needs token-precise truncation.

### Design notes

- Counting messages, not just text, because most models add per-message overhead (role markers, separators).
- Async because some tokenizers may need to lazy-load weights.
- Aria does not ship a tokenizer in core. `AriaApple` provides `BPETokenizer` (configurable) and a wrapper around FoundationModels' token estimator. The default `HistoryPolicy.lastN` does not require a tokenizer.

## Implementation responsibilities (in `AriaApple`)

Concrete implementations live in `AriaApple/Providers/` and conform to the protocols above. They handle:

- Translating `[Message]` to the provider's native format (e.g., FoundationModels `Transcript`).
- Translating `[ToolDefinition]` to the provider's native tool shape.
- Mapping native streaming events to `ProviderEvent`.
- Honoring `GenerationOptions` (mapping the cross-platform options to provider knobs).
- Reporting accurate `ProviderCapabilities`.

The agent layer never sees the provider's native types.

## What this layer does NOT include

- Concrete provider implementations. Those live in `AriaApple`.
- HTTP clients. `Aria` does not import `URLSession`. If a remote provider is needed, the user injects an `HTTPClient`.
- The agent loop. Providers are providers; the loop is in Layer 5.
- Memory. Embedders live here, but `VectorStore` and `MemoryStore` are Layer 4.

## Testing

The Provider layer is tested via `MockLLMProvider` (in `AriaTesting`):

```swift
public final class MockLLMProvider: LLMProvider, @unchecked Sendable {
    public var scriptedResponses: [[ProviderEvent]]
    public init(scripted: [[ProviderEvent]]) { ... }
    public func stream(...) -> AsyncThrowingStream<ProviderEvent, Error> {
        // emits the next scripted response
    }
}
```

Used in agent tests to drive deterministic agent behavior.

## Future considerations

- **Provider lifecycle.** Today providers are stateless `Sendable` values. If a provider needs initialization (loading weights), it can do so in `init` or expose a `prepare()` method. Avoid building a complex lifecycle protocol prematurely.
- **Streaming embedders.** Long-input embedding could stream chunks. Defer until a real embedder needs it.
- **Tool versioning.** `ToolDefinition` doesn't include a version. If tool definitions need to evolve while old agent runs are mid-flight, add `version: String?` to the definition.
- **Multimodal output.** Today providers emit text and tool calls. Audio/image output would extend `ProviderEvent` with new cases.
