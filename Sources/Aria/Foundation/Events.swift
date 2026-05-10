import Foundation

// MARK: - FinishReason

/// Why a model or agent run ended.
public enum FinishReason: String, Sendable, Equatable, Codable {
    /// The model completed its turn naturally.
    case endTurn
    /// The model stopped because it hit a token limit.
    case maxTokens
    /// The model emitted tool calls and is waiting for results.
    case toolUse
    /// The model stopped because it hit a configured stop sequence.
    case stopSequence
    /// The model refused to respond.
    case refusal
    /// The provider returned an error.
    case error
    /// The agent loop hit its `maxSteps` limit.
    case maxStepsReached
    /// The run was cancelled by the consumer.
    case cancelled
}

// MARK: - TokenUsage

/// Token-count metrics reported by a provider.
public struct TokenUsage: Sendable, Equatable, Codable {
    // MARK: Lifecycle

    public init(
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int? = nil,
        cacheCreationTokens: Int? = nil
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
    }

    // MARK: Public

    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheReadTokens: Int?
    public let cacheCreationTokens: Int?
}

// MARK: - ProviderEvent

/// What an `LLMProvider` emits while streaming a response.
///
/// `ProviderEvent` is the producer-side stream type. The agent loop
/// translates these into `AgentEvent`s for downstream consumers.
///
/// Two flavors of tool call exist:
///
/// - **Streamed tool call** (`toolCallStart` → `toolCallDelta`* →
///   `toolCallEnd`): the provider asks the agent to invoke a tool. The
///   agent collects the call and runs it via its tool registry. Used by
///   providers whose model emits structured tool-call requests but does
///   not execute tools itself.
///
/// - **Provider-executed tool call** (`toolCallExecuted`): the provider
///   has already invoked the tool and produced a result. This applies
///   to providers like Apple FoundationModels whose native session API
///   resolves tools internally. The agent does not re-execute; it
///   records the result and surfaces equivalent events to consumers.
public enum ProviderEvent: Sendable, Equatable {
    case messageStart(messageId: String)
    case textDelta(String)
    case toolCallStart(ToolCall)
    case toolCallDelta(id: String, argumentsDelta: String)
    case toolCallEnd(id: String)
    case toolCallExecuted(call: ToolCall, result: ToolExecutionResult)
    case messageStop(FinishReason)
    case usage(TokenUsage)
}

// MARK: - ToolExecutionResult

/// The outcome of executing a tool.
public struct ToolExecutionResult: Sendable, Equatable, Codable {
    // MARK: Lifecycle

    public init(output: JSONValue, isError: Bool = false, duration: Duration = .zero) {
        self.output = output
        self.isError = isError
        self.duration = duration
    }

    // MARK: Public

    public let output: JSONValue
    public let isError: Bool
    public let duration: Duration
}

// MARK: - AgentEvent

/// What the agent emits as it runs.
///
/// Higher-level than `ProviderEvent`: includes step boundaries, tool
/// execution events, and lifecycle markers that consumers (UI, tests,
/// observers) need.
public enum AgentEvent: Sendable, Equatable {
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
