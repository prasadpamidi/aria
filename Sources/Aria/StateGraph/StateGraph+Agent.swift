import Foundation

// MARK: - Agent-as-node helper

extension StateGraph {
    /// Register a node that runs `agent.stream(_:)`, accumulates the
    /// streaming text reply, and writes the result back into the
    /// state. Common case for graphs that chain LLM calls.
    ///
    /// - Parameters:
    ///   - name: Node name used for routing and event labels.
    ///   - agent: The `Agent` to invoke. Captured by the closure;
    ///     because `Agent` is `Sendable` the same instance can be
    ///     reused across many nodes.
    ///   - prompt: Builds the user prompt string from the current
    ///     state. Called once per node execution.
    ///   - writeResult: Mutates the state with the agent's final
    ///     reply text. The closure receives an `inout State` so
    ///     callers can update any field without rebuilding the value.
    public mutating func addAgentNode(
        _ name: String,
        agent: Agent,
        prompt: @Sendable @escaping (State) -> String,
        writeResult: @Sendable @escaping (inout State, String) -> Void
    ) {
        self.addNode(name) { state in
            let input = AgentInput.message(.user(prompt(state)))
            var text = ""
            for try await event in agent.stream(input) {
                if case let .textDelta(chunk) = event {
                    text += chunk
                }
            }
            var copy = state
            writeResult(&copy, text)
            return copy
        }
    }
}
