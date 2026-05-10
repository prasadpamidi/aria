import Foundation

// MARK: - Checkpoint

/// A snapshot of an agent's `AgentState` at a single point in time.
///
/// Checkpoints are opaque from the perspective of the storage layer:
/// `state` carries the encoded `AgentState` bytes; the agent serializes
/// and deserializes via `Codable` on either side. This decouples the
/// checkpoint storage from the evolving shape of `AgentState`.
public struct Checkpoint: Sendable, Codable, Equatable {
    // MARK: Lifecycle

    public init(
        id: String = UUID().uuidString,
        threadId: String,
        parentId: String? = nil,
        createdAt: Date = Date(),
        state: Data,
        metadata: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.threadId = threadId
        self.parentId = parentId
        self.createdAt = createdAt
        self.state = state
        self.metadata = metadata
    }

    // MARK: Public

    public let id: String
    public let threadId: String
    public let parentId: String?
    public let createdAt: Date
    public let state: Data
    public let metadata: [String: JSONValue]
}

// MARK: - Checkpointer

/// Stores and retrieves `Checkpoint`s.
///
/// Used by agents that need to resume after a crash, replay a prior
/// trajectory (time travel), or pause for human-in-the-loop confirmation
/// and resume later.
public protocol Checkpointer: Sendable {
    /// Persist a checkpoint. Implementations may overwrite a checkpoint
    /// with the same `id` or treat each insert as new — the agent layer
    /// always passes a unique id.
    func put(_ checkpoint: Checkpoint, threadId: String) async throws

    /// Load a specific checkpoint, or the latest for the thread when
    /// `checkpointId` is `nil`.
    func get(threadId: String, checkpointId: String?) async throws -> Checkpoint?

    /// List checkpoints for a thread, newest first.
    func list(threadId: String, limit: Int) async throws -> [Checkpoint]

    /// Remove every checkpoint in the thread.
    func deleteThread(_ threadId: String) async throws
}

extension Checkpointer {
    /// Convenience: load the latest checkpoint for a thread.
    public func latest(threadId: String) async throws -> Checkpoint? {
        try await self.get(threadId: threadId, checkpointId: nil)
    }
}

// MARK: - InMemoryCheckpointer

/// A `Checkpointer` backed by an actor-isolated dictionary.
///
/// Used by tests and trivial production cases (single-session agents
/// that don't need to survive process restarts).
public actor InMemoryCheckpointer: Checkpointer {
    // MARK: Lifecycle

    public init() { }

    // MARK: Public

    public func put(_ checkpoint: Checkpoint, threadId: String) async throws {
        self.store[threadId, default: []].append(checkpoint)
    }

    public func get(
        threadId: String,
        checkpointId: String?
    ) async throws -> Checkpoint? {
        let entries = self.store[threadId] ?? []
        guard !entries.isEmpty else {
            return nil
        }
        if let checkpointId {
            return entries.first { $0.id == checkpointId }
        }
        return entries.max(by: { $0.createdAt < $1.createdAt })
    }

    public func list(threadId: String, limit: Int) async throws -> [Checkpoint] {
        let entries = self.store[threadId] ?? []
        let sorted = entries.sorted(by: { $0.createdAt > $1.createdAt })
        if limit < sorted.count {
            return Array(sorted.prefix(limit))
        }
        return sorted
    }

    public func deleteThread(_ threadId: String) async throws {
        self.store[threadId] = []
    }

    // MARK: Private

    private var store: [String: [Checkpoint]] = [:]
}
