import Foundation
import Logging

private let historyLogger = Logger(label: "com.aria.agent.history")

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
        let lastPreview = loaded.last.map { Self.preview(of: $0) } ?? "(none)"
        let beforeRunMessage = "[beforeRun] thread=\(state.threadId) loaded=\(loaded.count) " +
            "incoming=\(state.messages.count) total=\(newState.messages.count) " +
            "lastLoaded={\(lastPreview)}"
        historyLogger.info("\(beforeRunMessage)")
        return newState
    }

    public func afterStep(_ state: AgentState) async throws -> AgentState {
        let baseline = self.locked {
            self.lastPersistedCount[state.threadId, default: 0]
        }
        let totalCount = state.messages.count
        guard totalCount > baseline else {
            historyLogger.debug(
                "[afterStep] thread=\(state.threadId) no-op baseline=\(baseline) total=\(totalCount)"
            )
            return state
        }
        let newMessages = Array(state.messages[baseline..<totalCount])
        try await self.history.appendAll(newMessages, threadId: state.threadId)
        self.locked { self.lastPersistedCount[state.threadId] = totalCount }
        let breakdown = newMessages.map { Self.preview(of: $0) }.joined(separator: " | ")
        let afterStepMessage = "[afterStep] thread=\(state.threadId) persisted=\(newMessages.count) " +
            "baseline=\(baseline) total=\(totalCount) deltas={\(breakdown)}"
        historyLogger.info("\(afterStepMessage)")
        return state
    }

    // MARK: Private

    private let history: any ChatHistory
    private let lock = NSLock()
    private var lastPersistedCount: [String: Int] = [:]

    /// Compact role + truncated-text rendering used by the log lines so
    /// you can see WHAT moved through history without dumping multi-KB
    /// JSON blobs into the log buffer.
    private static func preview(of message: Message) -> String {
        let text = message.textContent
        let trimmed = text.count > 80
            ? String(text.prefix(80)) + "…"
            : text
        return "\(message.role.rawValue):\(trimmed)"
    }

    private func locked<T>(_ block: () -> T) -> T {
        self.lock.lock()
        defer { self.lock.unlock() }
        return block()
    }
}
