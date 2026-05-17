import Foundation

// MARK: - LLMProvider

/// The protocol every concrete LLM implementation conforms to.
///
/// Implementations live outside the core target (`AriaApple` provides
/// FoundationModels and MLX adapters; consumers may write their own).
/// The agent layer talks only to this protocol — providers are
/// substitutable.
public protocol LLMProvider: Sendable {
    /// Static metadata describing what this provider supports.
    var capabilities: ProviderCapabilities { get }

    /// Stream the provider's response to a list of messages.
    ///
    /// Implementations emit `ProviderEvent`s as the underlying model
    /// produces them. The stream finishes (with success or error) when
    /// the model reaches a terminal state.
    ///
    /// Most providers receive only `ToolDefinition`s and let the agent
    /// dispatch tools after the stream finishes. Providers whose model
    /// session executes tools internally (Apple FoundationModels, for
    /// example) should override
    /// `stream(messages:executableTools:options:)` instead — that gives
    /// them access to the live `AnyTool` invocation closures.
    func stream(
        messages: [Message],
        tools: [ToolDefinition],
        options: GenerationOptions
    ) -> AsyncThrowingStream<ProviderEvent, any Error>
}

extension LLMProvider {
    /// Stream with executable `AnyTool`s instead of bare definitions.
    ///
    /// Providers that resolve tools inside their own model session (e.g.
    /// `FoundationModelsProvider`) override this method to use the
    /// `AnyTool` invocation closures directly and emit
    /// `ProviderEvent.toolCallExecuted` once each call resolves.
    /// Providers that prefer to surface tool-call requests to the agent
    /// layer can rely on the default forwarding implementation.
    public func stream(
        messages: [Message],
        executableTools: [AnyTool],
        options: GenerationOptions
    ) -> AsyncThrowingStream<ProviderEvent, any Error> {
        self.stream(
            messages: messages,
            tools: executableTools.map(\.definition),
            options: options
        )
    }
}

// MARK: - ProviderCapabilities

/// What a given `LLMProvider` instance can do.
///
/// The agent layer reads capabilities to adapt behavior — e.g., serializing
/// tool calls when `supportsParallelToolCalls` is `false`, or falling back
/// to prompt-based tool emission when `supportsToolUse` is `false`.
public struct ProviderCapabilities: Sendable, Equatable, Codable {
    // MARK: Lifecycle

    public init(
        modelIdentifier: String,
        supportsStreaming: Bool = true,
        supportsToolUse: Bool = false,
        supportsParallelToolCalls: Bool = false,
        supportsVision: Bool = false,
        supportsAudio: Bool = false,
        supportsStructuredOutput: Bool = false,
        supportsSystemPrompt: Bool = true,
        maxContextTokens: Int? = nil
    ) {
        self.modelIdentifier = modelIdentifier
        self.supportsStreaming = supportsStreaming
        self.supportsToolUse = supportsToolUse
        self.supportsParallelToolCalls = supportsParallelToolCalls
        self.supportsVision = supportsVision
        self.supportsAudio = supportsAudio
        self.supportsStructuredOutput = supportsStructuredOutput
        self.supportsSystemPrompt = supportsSystemPrompt
        self.maxContextTokens = maxContextTokens
    }

    // MARK: Public

    public let modelIdentifier: String
    public let supportsStreaming: Bool
    public let supportsToolUse: Bool
    public let supportsParallelToolCalls: Bool
    public let supportsVision: Bool
    public let supportsAudio: Bool
    public let supportsStructuredOutput: Bool
    public let supportsSystemPrompt: Bool
    public let maxContextTokens: Int?
}

// MARK: - GenerationOptions

/// Per-call generation parameters.
///
/// These are the cross-platform knobs every provider should honor. For
/// provider-specific tuning, use `providerSpecific` — values there are
/// passed through unchanged.
public struct GenerationOptions: Sendable, Equatable {
    // MARK: Lifecycle

    public init(
        temperature: Double? = nil,
        topP: Double? = nil,
        topK: Int? = nil,
        maxTokens: Int? = nil,
        stopSequences: [String] = [],
        responseFormat: ResponseFormat? = nil,
        seed: UInt64? = nil,
        providerSpecific: [String: JSONValue] = [:]
    ) {
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.maxTokens = maxTokens
        self.stopSequences = stopSequences
        self.responseFormat = responseFormat
        self.seed = seed
        self.providerSpecific = providerSpecific
    }

    // MARK: Public

    public var temperature: Double?
    public var topP: Double?
    public var topK: Int?
    public var maxTokens: Int?
    public var stopSequences: [String]
    public var responseFormat: ResponseFormat?
    public var seed: UInt64?
    public var providerSpecific: [String: JSONValue]
}

// MARK: - ResponseFormat

/// How the model should structure its output.
public enum ResponseFormat: Sendable, Equatable {
    /// Free-form text. Default.
    case text
    /// JSON without a specific schema. Provider chooses the shape.
    case json
    /// JSON conforming to a specific schema.
    case schema(JSONSchema)
    /// JSON conforming to an opaque JSON Schema dict. Escape hatch for
    /// schemas Aria's typed `JSONSchema` enum can't round-trip (e.g.
    /// FoundationModels' `GenerationSchema` for a `Generable` with
    /// nested array-of-Generable fields, which encodes using `$ref` /
    /// `$defs` — features the typed enum doesn't model).
    ///
    /// Providers should serialize the wrapped `JSONValue` as JSON in
    /// whatever vendor-specific schema slot they use. Equivalent to
    /// `.schema(...)` for transport purposes; the difference is that
    /// `.schema` carries the typed model (manipulable, inspectable) and
    /// `.rawSchema` is a passthrough for shapes outside that model.
    case rawSchema(JSONValue)
}
