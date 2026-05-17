import Foundation

// MARK: - HistorySummarizationMiddleware

/// Compresses the older portion of conversation history into a single
/// summary system message when the message count exceeds a trigger
/// threshold, preserving the most recent turns verbatim.
///
/// **What this is for.** `HistoryWindowMiddleware` drops oldest turns
/// to fit a budget — works for thread-bounded sessions, loses gist for
/// long-running threads. Summarization preserves the *meaning* of
/// older turns by collapsing them into one cheap-to-carry system
/// message: "user is vegetarian, prefers strength training mornings,
/// has a knee injury…" The thread can grow indefinitely; tokens stay
/// bounded; the model still "remembers" what mattered.
///
/// **What it preserves.** All pre-existing system messages stay above
/// the summary (instructions + RAG recall don't get summarized).
/// The most recent `keepRecentTurns` non-system messages survive
/// verbatim (recent turns are usually the most context-sensitive).
/// The summary itself becomes a new `.system` message inserted between
/// the original systems and the kept-recent tail.
///
/// **Cost.** One summarizer call per `beforeStep` where the threshold
/// is met. The summarizer is typically a cheap LLM (gpt-4o-mini-ish)
/// — call it once per ~20 conversation turns, not once per turn, so
/// in practice the amortized cost is small. The middleware does *not*
/// cache summaries; if you re-run with the same state above-threshold,
/// you'll re-summarize the same slice. That's fine because in normal
/// agent flow each turn calls `beforeStep` exactly once. If you want
/// cross-turn caching, persist the summary as a `.system` message via
/// `HistoryMiddleware` and have your store carry it forward.
///
/// **Graceful degradation.** If the summarizer throws, the middleware
/// leaves state untouched and the turn proceeds with the full
/// untrimmed history. Losing a turn over a summarizer outage is worse
/// than a slow turn with a long prompt — fail-open is the right
/// default here.
///
/// **Ordering.** Pair with `HistoryMiddleware` (loads from store) and
/// `HistoryWindowMiddleware` (hard cap). Typical chain:
///   1. `HistoryMiddleware` — load persisted history
///   2. `HistorySummarizationMiddleware` — compress older portion
///   3. `HistoryWindowMiddleware` — hard cap belt-and-braces
///   4. `RAGMiddleware` — prepend recalled facts
public struct HistorySummarizationMiddleware: AgentMiddleware {
    // MARK: Lifecycle

    /// - Parameters:
    ///   - triggerAfterTurns: When the count of non-system messages
    ///     exceeds this number, the middleware fires. Equality is the
    ///     boundary; strict-greater-than triggers.
    ///   - keepRecentTurns: How many of the most recent non-system
    ///     messages to keep verbatim (not summarized). Anything older
    ///     gets compressed.
    ///   - summarizer: Async function the middleware calls with the
    ///     older non-system slice, returns the summary text that
    ///     becomes the new `.system` message. Errors are swallowed
    ///     (state passes through unchanged on failure).
    public init(
        triggerAfterTurns: Int,
        keepRecentTurns: Int,
        summarizer: @escaping @Sendable ([Message]) async throws -> String
    ) {
        self.triggerAfterTurns = triggerAfterTurns
        self.keepRecentTurns = keepRecentTurns
        self.summarizer = summarizer
        self.cache = SummaryCache()
    }

    // MARK: Public

    public func beforeStep(_ state: AgentState) async throws -> AgentState {
        // Partition into systems (always preserved) and the rest.
        var systems: [Message] = []
        var nonSystem: [Message] = []
        for message in state.messages {
            if message.role == .system {
                systems.append(message)
            } else {
                nonSystem.append(message)
            }
        }

        // Trigger gate: strictly more non-system messages than the
        // threshold, AND there's an actual older slice to summarize
        // after carving out `keepRecentTurns`.
        guard nonSystem.count > self.triggerAfterTurns,
              nonSystem.count > self.keepRecentTurns else {
            return state
        }

        let pivot = nonSystem.count - self.keepRecentTurns
        let older = Array(nonSystem.prefix(pivot))
        let recent = Array(nonSystem.suffix(self.keepRecentTurns))

        // Cache check: keyed on (threadId, hash of older slice text).
        // A cache hit reuses the cached `summaryMessage` verbatim —
        // including its `createdAt` — so consecutive `beforeStep`
        // calls with the same older slice produce identical state.
        let olderHash = Self.olderSliceHash(older)
        if let cached = self.cache.get(threadId: state.threadId, olderSliceHash: olderHash) {
            var newState = state
            newState.messages = systems + [cached] + recent
            return newState
        }

        // Summarize. Fail-open: any error leaves state untouched.
        let summary: String
        do {
            summary = try await self.summarizer(older)
        } catch {
            return state
        }

        let summaryMessage = Message.system(
            "Earlier conversation summary:\n\(summary)"
        )
        self.cache.put(
            threadId: state.threadId,
            olderSliceHash: olderHash,
            summaryMessage: summaryMessage
        )
        var newState = state
        newState.messages = systems + [summaryMessage] + recent
        return newState
    }

    // MARK: Private

    private let triggerAfterTurns: Int
    private let keepRecentTurns: Int
    private let summarizer: @Sendable ([Message]) async throws -> String
    private let cache: SummaryCache

    /// Stable hash over the text content of the older slice. Used
    /// as the cache key so a slice that exactly matches a prior call
    /// reuses the summary verbatim. Includes roles so a
    /// user/assistant ordering swap invalidates the cache.
    private static func olderSliceHash(_ messages: [Message]) -> Int {
        var hasher = Hasher()
        for message in messages {
            hasher.combine(message.role.rawValue)
            hasher.combine(message.textContent)
        }
        return hasher.finalize()
    }
}

// MARK: - SummaryCache

/// Per-process LRU-ish cache of summary messages, keyed on
/// `(threadId, hash-of-older-slice)`. Reference-typed so the enclosing
/// `HistorySummarizationMiddleware` struct can mutate it from
/// non-mutating methods.
///
/// One entry per `threadId` is enough — a new older-slice hash
/// overwrites the prior cached summary for that thread. (When the
/// slice changes, the prior summary is stale anyway.)
///
/// `@unchecked Sendable` because the lock guarantees serialized
/// access; Swift 6's checker can't infer that from `NSLock`.
private final class SummaryCache: @unchecked Sendable {
    // MARK: Internal

    func get(threadId: String, olderSliceHash: Int) -> Message? {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard let entry = self.entries[threadId],
              entry.olderSliceHash == olderSliceHash else {
            return nil
        }
        return entry.summaryMessage
    }

    func put(threadId: String, olderSliceHash: Int, summaryMessage: Message) {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.entries[threadId] = Entry(
            olderSliceHash: olderSliceHash,
            summaryMessage: summaryMessage
        )
    }

    // MARK: Private

    private struct Entry {
        let olderSliceHash: Int
        let summaryMessage: Message
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
}
