import Foundation

// MARK: - ChatHistory

/// Stores the messages that make up a conversation thread.
///
/// `ChatHistory` is the simplest of Aria's memory protocols. Implementations
/// persist messages keyed by an opaque `threadId` so an agent can pick up
/// where a previous run left off. The protocol is append-only by design;
/// edits are modeled as new messages.
public protocol ChatHistory: Sendable {
    /// Append a single message to the given thread.
    func append(_ message: Message, threadId: String) async throws

    /// Append a batch of messages atomically to the given thread.
    func appendAll(_ messages: [Message], threadId: String) async throws

    /// Return the messages for a thread in chronological order.
    ///
    /// - Parameters:
    ///   - threadId: the thread to read.
    ///   - limit: optional cap on the number of returned messages; when set,
    ///     returns the *last* `limit` messages so a UI can paginate from the
    ///     tail of the conversation.
    ///   - before: optional `createdAt` cutoff; when set, returns messages
    ///     strictly before this date.
    func messages(
        threadId: String,
        limit: Int?,
        before: Date?
    ) async throws -> [Message]

    /// Remove every message in the thread.
    func clear(threadId: String) async throws

    /// List the thread ids known to this store.
    func threads() async throws -> [String]
}

extension ChatHistory {
    /// Default batch implementation: appends one message at a time.
    /// Persistent backends should override with a transaction.
    public func appendAll(_ messages: [Message], threadId: String) async throws {
        for message in messages {
            try await self.append(message, threadId: threadId)
        }
    }

    /// Convenience overload: load all messages for a thread.
    public func messages(threadId: String) async throws -> [Message] {
        try await self.messages(threadId: threadId, limit: nil, before: nil)
    }
}

// MARK: - InMemoryChatHistory

/// A `ChatHistory` backed by an actor-isolated dictionary.
///
/// Suitable for tests, transient conversations, and Linux test runs.
/// Persistent backends live in platform modules (`AriaApple` ships
/// `GRDBChatHistory` for SQLite-backed persistence).
public actor InMemoryChatHistory: ChatHistory {
    // MARK: Lifecycle

    public init() { }

    // MARK: Public

    public func append(_ message: Message, threadId: String) async throws {
        self.store[threadId, default: []].append(message)
    }

    public func appendAll(_ messages: [Message], threadId: String) async throws {
        self.store[threadId, default: []].append(contentsOf: messages)
    }

    public func messages(
        threadId: String,
        limit: Int?,
        before: Date?
    ) async throws -> [Message] {
        let all = self.store[threadId] ?? []
        let filtered: [Message] =
            if let before {
                all.filter { $0.createdAt < before }
            } else {
                all
            }
        if let limit, limit < filtered.count {
            return Array(filtered.suffix(limit))
        }
        return filtered
    }

    public func clear(threadId: String) async throws {
        // Remove the key entirely (not just empty the array) so the
        // thread disappears from `threads()`. Matches
        // `GRDBChatHistory.clear`, whose `SELECT DISTINCT threadId
        // FROM messages` returns nothing after a delete — and matches
        // `HistoryRetentionPolicy`'s expectation that a cleared
        // thread is gone, not just inert.
        self.store.removeValue(forKey: threadId)
    }

    public func threads() async throws -> [String] {
        Array(self.store.keys)
    }

    // MARK: Private

    private var store: [String: [Message]] = [:]
}
