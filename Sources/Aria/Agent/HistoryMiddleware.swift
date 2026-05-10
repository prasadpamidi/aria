import Foundation

// MARK: - HistoryMiddleware

/// Loads stored conversation history into the agent's state at the
/// start of each run, then persists every new message back to the same
/// store after every step.
///
/// Wiring this middleware into an `AgentConfig` is enough to give an
/// agent durable memory across runs and process restarts. Consumers
/// only need to send the **new** user message via `AgentInput`; the
/// middleware prepends any prior turns it finds in storage.
///
/// Per-thread accounting tracks how many messages have already been
/// persisted, so subsequent `afterStep` calls forward only the deltas.
public final class HistoryMiddleware: AgentMiddleware, @unchecked Sendable {
    // MARK: Lifecycle

    public init(history: any ChatHistory) {
        self.history = history
    }

    // MARK: Public

    public func beforeRun(_ state: AgentState) async throws -> AgentState {
        // Load any prior messages for this thread and prepend them in
        // chronological order. The loaded messages are *already* in
        // storage, so the persistence baseline starts at their count —
        // we only persist what the agent loop appends from here on.
        let loaded = try await history.messages(threadId: state.threadId)
        var newState = state
        newState.messages = loaded + state.messages
        self.locked { self.lastPersistedCount[state.threadId] = loaded.count }
        return newState
    }

    public func afterStep(_ state: AgentState) async throws -> AgentState {
        let baseline = self.locked {
            self.lastPersistedCount[state.threadId, default: 0]
        }
        let totalCount = state.messages.count
        guard totalCount > baseline else {
            return state
        }
        let newMessages = Array(state.messages[baseline..<totalCount])
        try await self.history.appendAll(newMessages, threadId: state.threadId)
        self.locked { self.lastPersistedCount[state.threadId] = totalCount }
        return state
    }

    // MARK: Private

    private let history: any ChatHistory
    private let lock = NSLock()
    private var lastPersistedCount: [String: Int] = [:]

    private func locked<T>(_ block: () -> T) -> T {
        self.lock.lock()
        defer { self.lock.unlock() }
        return block()
    }
}
