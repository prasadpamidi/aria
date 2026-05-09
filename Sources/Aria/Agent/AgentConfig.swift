import Foundation

// MARK: - AgentConfig

/// Static configuration for an `Agent`.
///
/// `AgentConfig` is a value type; the agent reads it but never modifies
/// it. Construct one config per agent identity and reuse across calls.
public struct AgentConfig: Sendable {
    // MARK: Lifecycle

    public init(
        provider: any LLMProvider,
        tools: [AnyTool] = [],
        systemPrompt: String? = nil,
        threadId: String? = nil,
        generationOptions: GenerationOptions = .init(),
        middleware: [any AgentMiddleware] = [],
        maxSteps: Int = 10,
        parallelToolCalls: Bool = true,
        toolTimeout: Duration = .seconds(60)
    ) {
        self.provider = provider
        self.tools = tools
        self.systemPrompt = systemPrompt
        self.threadId = threadId
        self.generationOptions = generationOptions
        self.middleware = middleware
        self.maxSteps = maxSteps
        self.parallelToolCalls = parallelToolCalls
        self.toolTimeout = toolTimeout
    }

    // MARK: Public

    /// The LLM that drives the loop.
    public let provider: any LLMProvider

    /// Tools available for the model to call. The set is fixed for the
    /// life of the config; dynamic tool addition is a future feature.
    public let tools: [AnyTool]

    /// Optional system prompt prepended to every step's messages.
    public let systemPrompt: String?

    /// If `nil`, the agent generates a fresh thread id for each run.
    public let threadId: String?

    /// Generation options forwarded to the provider on every step.
    public let generationOptions: GenerationOptions

    /// Lifecycle hooks invoked around the loop. Order matters — the
    /// agent applies them sequentially, threading `AgentState` through.
    public let middleware: [any AgentMiddleware]

    /// Maximum number of provider invocations per run before the agent
    /// gives up with `FinishReason.maxStepsReached`.
    public let maxSteps: Int

    /// When `true` and the provider supports it, multiple tool calls
    /// from a single step run concurrently via `TaskGroup`.
    public let parallelToolCalls: Bool

    /// Per-tool execution timeout. Triggers `AgentError.timeout`.
    public let toolTimeout: Duration
}

extension AgentConfig {
    /// Look up a registered tool by name. Used by the agent loop when a
    /// `ToolCall` arrives from the provider.
    func tool(named name: String) -> AnyTool? {
        self.tools.first { $0.name == name }
    }
}
