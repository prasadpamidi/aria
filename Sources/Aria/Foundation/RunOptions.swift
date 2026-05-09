import Foundation

// MARK: - RunOptions

/// Per-invocation configuration threaded through every agent or runnable
/// call.
///
/// `RunOptions` carries identity, observability, and deadline information.
/// Cancellation is handled via Swift Concurrency's `Task` cancellation
/// — there is no separate cancellation token; check `Task.isCancelled`
/// inside long-running operations.
public struct RunOptions: Sendable {
    // MARK: Lifecycle

    public init(
        runId: UUID = UUID(),
        parentRunId: UUID? = nil,
        tags: [String] = [],
        metadata: [String: JSONValue] = [:],
        deadline: ContinuousClock.Instant? = nil
    ) {
        self.runId = runId
        self.parentRunId = parentRunId
        self.tags = tags
        self.metadata = metadata
        self.deadline = deadline
    }

    // MARK: Public

    public var runId: UUID
    public var parentRunId: UUID?
    public var tags: [String]
    public var metadata: [String: JSONValue]

    /// Optional absolute deadline. Implementations that perform long-running
    /// work check this between iterations and surface
    /// `AgentError.timeout` if the deadline passes.
    public var deadline: ContinuousClock.Instant?
}

// MARK: - Deadline helpers

extension RunOptions {
    /// Returns `true` if `deadline` is set and has already passed.
    public var hasExceededDeadline: Bool {
        guard let deadline else {
            return false
        }
        return ContinuousClock.now >= deadline
    }

    /// Throws `AgentError.timeout` if the deadline has passed, or
    /// `AgentError.cancelled` if the current `Task` is cancelled.
    public func checkpoint() throws {
        if Task.isCancelled {
            throw AgentError.cancelled
        }
        if let deadline, ContinuousClock.now >= deadline {
            throw AgentError.timeout(.zero)
        }
    }
}
