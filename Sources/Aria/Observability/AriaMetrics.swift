import Foundation
import Metrics

// MARK: - AriaMetrics

/// Lazily-created metrics emitted by Aria. Each property returns a
/// fresh metric handle bound to swift-metrics' `MetricsSystem`. The
/// default factory is no-op, so importing Aria adds zero overhead
/// until a consumer bootstraps a metrics backend.
///
/// Names follow OpenTelemetry GenAI metric conventions where they
/// apply (`gen_ai.client.token.usage`,
/// `gen_ai.client.operation.duration`) and an `aria.*` namespace for
/// runtime-specific signals.
public enum AriaMetrics {
    // MARK: - Aria-specific metrics

    /// Counter incremented every time the agent's main loop completes
    /// a step (regardless of outcome).
    public static var agentStepsTotal: Counter {
        Counter(label: "aria.agent.steps_total")
    }

    /// Counter for memory recall calls.
    public static var memoryRecallsTotal: Counter {
        Counter(label: "aria.memory.recalls_total")
    }

    /// Counter for memory remember calls.
    public static var memoryRemembersTotal: Counter {
        Counter(label: "aria.memory.remembers_total")
    }

    // MARK: - GenAI conventional metrics

    /// Histogram of token usage per request, dimensioned by
    /// `gen_ai.token.type` ("input" / "output") and `gen_ai.system`.
    /// Recorded at the close of each provider stream when the
    /// provider reports usage.
    public static func tokenUsage(system: String, type: String) -> Recorder {
        Recorder(
            label: "gen_ai.client.token.usage",
            dimensions: [
                ("gen_ai.system", system),
                ("gen_ai.token.type", type),
            ]
        )
    }

    /// Histogram of provider operation duration in seconds.
    public static func operationDuration(system: String, operation: String) -> Recorder {
        Recorder(
            label: "gen_ai.client.operation.duration",
            dimensions: [
                ("gen_ai.system", system),
                ("gen_ai.operation.name", operation),
            ]
        )
    }

    /// Counter incremented every time a tool finishes executing,
    /// dimensioned by tool name and whether the result was an error.
    public static func toolExecutionsTotal(name: String, isError: Bool) -> Counter {
        Counter(
            label: "aria.tool.executions_total",
            dimensions: [
                ("tool.name", name),
                ("tool.is_error", String(isError)),
            ]
        )
    }

    /// Histogram of per-tool execution duration in seconds.
    public static func toolDuration(name: String) -> Recorder {
        Recorder(
            label: "aria.tool.duration_seconds",
            dimensions: [("tool.name", name)]
        )
    }

    /// Counter incremented per StateGraph node execution (linear or
    /// parallel branch). Dimensioned by node name.
    public static func stateGraphNodeExecutions(name: String) -> Counter {
        Counter(
            label: "aria.state_graph.node_executions_total",
            dimensions: [("node.name", name)]
        )
    }
}
