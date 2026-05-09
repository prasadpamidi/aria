import Foundation

// MARK: - AgentMiddleware

/// A hook into the agent control loop.
///
/// Middleware receives the current `AgentState` at four lifecycle points
/// and may return a modified state. Cross-cutting concerns — RAG context
/// injection, fact extraction, logging, metrics — are middlewares.
///
/// Every method has a no-op default. Implementations override only the
/// hooks they care about.
public protocol AgentMiddleware: Sendable {
    /// Called once before the agent's step loop begins, after the user
    /// input has been appended to `state.messages`.
    func beforeRun(_ state: AgentState) async throws -> AgentState

    /// Called before each step (each provider stream invocation).
    /// Use this to inject context (e.g., recalled memories) into
    /// `state.messages` or `state.scratchpad`.
    func beforeStep(_ state: AgentState) async throws -> AgentState

    /// Called after each step completes successfully, after any tool
    /// results have been appended. Use this to extract facts, write
    /// checkpoints, or update external systems.
    func afterStep(_ state: AgentState) async throws -> AgentState

    /// Called once when the agent reaches a terminal state.
    func afterRun(_ state: AgentState, finalEvent: AgentEvent) async throws -> AgentState
}

extension AgentMiddleware {
    public func beforeRun(_ state: AgentState) async throws -> AgentState {
        state
    }

    public func beforeStep(_ state: AgentState) async throws -> AgentState {
        state
    }

    public func afterStep(_ state: AgentState) async throws -> AgentState {
        state
    }

    public func afterRun(_ state: AgentState, finalEvent _: AgentEvent) async throws -> AgentState {
        state
    }
}
