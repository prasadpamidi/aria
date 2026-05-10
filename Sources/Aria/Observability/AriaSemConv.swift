import Foundation

// MARK: - AriaSemConv

/// Attribute keys Aria emits on its tracing spans and metrics.
///
/// The `genAI` namespace follows OpenTelemetry's GenAI semantic
/// conventions
/// (https://opentelemetry.io/docs/specs/semconv/gen-ai/) so any OTel
/// backend that auto-renders LLM workloads (Phoenix, Honeycomb, etc.)
/// recognizes these out of the box. The `aria` namespace covers
/// fields outside of GenAI's standard surface.
public enum AriaSemConv {
    /// OpenTelemetry GenAI semantic-convention attribute keys.
    public enum GenAI {
        /// Provider system. e.g. "anthropic", "openai",
        /// "apple.foundationmodels". Matches `gen_ai.system`.
        public static let system = "gen_ai.system"
        /// Model identifier sent in the request.
        /// Matches `gen_ai.request.model`.
        public static let requestModel = "gen_ai.request.model"
        /// The kind of operation: "chat", "structured_output",
        /// "tool_call". Matches `gen_ai.operation.name`.
        public static let operationName = "gen_ai.operation.name"
        /// Input token count. Matches `gen_ai.usage.input_tokens`.
        public static let inputTokens = "gen_ai.usage.input_tokens"
        /// Output token count. Matches `gen_ai.usage.output_tokens`.
        public static let outputTokens = "gen_ai.usage.output_tokens"
        /// Finish reason — array of strings.
        /// Matches `gen_ai.response.finish_reasons`.
        public static let finishReasons = "gen_ai.response.finish_reasons"
        /// Tool call name. Matches `gen_ai.tool.name`.
        public static let toolName = "gen_ai.tool.name"
        /// Tool call id. Matches `gen_ai.tool.call.id`.
        public static let toolCallId = "gen_ai.tool.call.id"
    }

    /// Aria-specific attribute keys outside the GenAI semconv.
    public enum Aria {
        public static let threadId = "aria.thread_id"
        public static let stepIndex = "aria.agent.step_index"
        public static let middlewareName = "aria.middleware.name"
        public static let stateGraphNode = "aria.state_graph.node"
        public static let stateGraphParallelBranches = "aria.state_graph.parallel.branches"
        public static let stateGraphReducerCount = "aria.state_graph.reducer_count"
        public static let memoryNamespace = "aria.memory.namespace"
        public static let memoryTopK = "aria.memory.top_k"
        public static let memoryMatches = "aria.memory.matches.count"
        public static let memoryItemId = "aria.memory.item.id"
    }

    /// Span names. Centralized so emitters and instrumentation tests
    /// can reference the same identifiers.
    public enum Span {
        public static let agentRun = "agent.run"
        public static let agentRespond = "agent.respond"
        public static let agentStep = "agent.step"
        public static let providerStream = "provider.stream"
        public static let providerStreamStructured = "provider.stream_structured"
        public static let toolExecute = "tool.execute"
        public static let middlewareBeforeRun = "middleware.before_run"
        public static let middlewareBeforeStep = "middleware.before_step"
        public static let middlewareAfterStep = "middleware.after_step"
        public static let middlewareAfterRun = "middleware.after_run"
        public static let stateGraphRun = "state_graph.run"
        public static let stateGraphResume = "state_graph.resume"
        public static let stateGraphNode = "state_graph.node"
        public static let stateGraphParallel = "state_graph.parallel"
        public static let memoryRecall = "memory.recall"
        public static let memoryRemember = "memory.remember"
    }
}
