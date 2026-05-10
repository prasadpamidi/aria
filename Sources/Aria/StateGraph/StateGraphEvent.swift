import Foundation

// MARK: - StateGraphEvent

/// Event emitted as a `CompiledStateGraph` runs.
public enum StateGraphEvent<State: Sendable & Codable>: Sendable {
    /// A node is about to execute. Carries the state that node will
    /// receive as input.
    case nodeStart(name: String, state: State)

    /// A node finished. Carries the state the node returned (which
    /// becomes the input for the next node, or the final state when
    /// the node's outgoing edge points at `StateGraph.end`).
    case nodeEnd(name: String, state: State)

    /// The graph reached `StateGraph.end`. Carries the final state.
    /// The stream finishes after this event.
    case finish(state: State)
}
