import Foundation

// MARK: - HistoryRetentionPolicy

/// Bounds disk growth of a `ChatHistory` store by evicting whole
/// threads that exceed configured limits.
///
/// **Why "whole-thread" eviction.** `ChatHistory`'s public surface
/// only supports `clear(threadId:)` (drop a whole thread) — not "drop
/// oldest N messages from a thread." That's deliberate: per-thread
/// summarization is best handled by `HistorySummarizationMiddleware`
/// at the agent layer, not by the storage layer. The retention policy
/// here is the disk-side complement — it expires whole conversations
/// that are stale or excess, not individual turns.
///
/// **What it bounds.**
///   - `maxThreadAgeDays`: a thread whose newest message is older
///     than this gets cleared. "Last activity" eviction.
///   - `maxThreadCount`: if more than this many threads exist (after
///     age eviction), the oldest are dropped until the count fits.
///     LRU-by-last-activity.
///
/// **What it does not bound.** Per-thread message count or per-thread
/// token total. Those are middleware-layer concerns
/// (`HistoryWindowMiddleware` caps what's *sent* to the provider;
/// `HistorySummarizationMiddleware`, when it lands, will cap what's
/// *stored* per thread).
///
/// **When to run it.** Not on every agent step — too much I/O. The
/// caller decides:
///   - On app startup (once per process)
///   - As a scheduled background job (e.g. daily)
///   - On low-disk-pressure system signals
///
/// The policy itself is stateless and idempotent; calling `enforce(on:)`
/// twice in a row drops the same set the first call drops, then nothing.
public struct HistoryRetentionPolicy: Sendable {
    // MARK: Lifecycle

    /// - Parameters:
    ///   - maxThreadAgeDays: Threads whose newest message is older
    ///     than this many days are cleared. `nil` disables age-based
    ///     eviction.
    ///   - maxThreadCount: After age eviction, if more than this many
    ///     threads remain, drop the oldest-activity threads until the
    ///     count fits. `nil` disables count-based eviction.
    public init(
        maxThreadAgeDays: Double? = nil,
        maxThreadCount: Int? = nil
    ) {
        self.maxThreadAgeDays = maxThreadAgeDays
        self.maxThreadCount = maxThreadCount
    }

    // MARK: Public

    /// What was evicted by an `enforce(on:)` pass. Useful for logging
    /// and tests; callers don't have to inspect it.
    public struct Report: Sendable, Equatable {
        // MARK: Lifecycle

        public init(threadsRemovedForAge: [String] = [], threadsRemovedForCount: [String] = []) {
            self.threadsRemovedForAge = threadsRemovedForAge
            self.threadsRemovedForCount = threadsRemovedForCount
        }

        // MARK: Public

        public var threadsRemovedForAge: [String]
        public var threadsRemovedForCount: [String]
    }

    /// Apply the policy to a `ChatHistory` store. Mutates the store in
    /// place; returns a `Report` describing what was evicted.
    @discardableResult
    public func enforce(on history: any ChatHistory) async throws -> Report {
        guard self.maxThreadAgeDays != nil || self.maxThreadCount != nil else {
            return Report()
        }
        let activity = try await Self.snapshotActivity(in: history)
        let removedForAge = try await self.evictByAge(activity: activity, in: history)
        let removedForCount = try await self.evictByCount(
            activity: activity,
            excluding: removedForAge,
            in: history
        )
        return Report(
            threadsRemovedForAge: removedForAge,
            threadsRemovedForCount: removedForCount
        )
    }

    // MARK: Internal

    // MARK: Internal helpers

    /// One thread's last-activity timestamp. Nil when the thread has
    /// no messages (corner case after a prior `clear`).
    struct ThreadActivity {
        let threadId: String
        let lastActivity: Date?
    }

    // MARK: Private

    private let maxThreadAgeDays: Double?
    private let maxThreadCount: Int?

    /// Snapshot each thread's last-activity timestamp once so the age
    /// pass and count pass operate on a consistent view.
    private static func snapshotActivity(in history: any ChatHistory) async throws -> [ThreadActivity] {
        let threadIds = try await history.threads()
        var snapshot: [ThreadActivity] = []
        for threadId in threadIds {
            let messages = try await history.messages(threadId: threadId)
            snapshot.append(ThreadActivity(threadId: threadId, lastActivity: messages.last?.createdAt))
        }
        return snapshot
    }

    /// Clear threads whose newest message is older than the configured
    /// age cap. Empty threads (no messages) are skipped — they're
    /// inert and won't accrue disk regardless.
    private func evictByAge(
        activity: [ThreadActivity],
        in history: any ChatHistory
    ) async throws -> [String] {
        guard let maxAgeDays = self.maxThreadAgeDays else {
            return []
        }
        let cutoff = Date().addingTimeInterval(-maxAgeDays * 86400)
        var removed: [String] = []
        for entry in activity {
            guard let lastActivity = entry.lastActivity, lastActivity < cutoff else {
                continue
            }
            try await history.clear(threadId: entry.threadId)
            removed.append(entry.threadId)
        }
        return removed
    }

    /// Among threads that survived the age pass, if we're still over
    /// `maxThreadCount`, drop oldest-activity threads. Threads with
    /// no activity sort to the front (treated as oldest).
    private func evictByCount(
        activity: [ThreadActivity],
        excluding ageEvicted: [String],
        in history: any ChatHistory
    ) async throws -> [String] {
        guard let maxCount = self.maxThreadCount else {
            return []
        }
        let evictedSet = Set(ageEvicted)
        let survivors = activity.filter { !evictedSet.contains($0.threadId) }
        guard survivors.count > maxCount else {
            return []
        }
        let sorted = survivors.sorted { lhs, rhs in
            (lhs.lastActivity ?? .distantPast) < (rhs.lastActivity ?? .distantPast)
        }
        let dropCount = survivors.count - maxCount
        var removed: [String] = []
        for entry in sorted.prefix(dropCount) {
            try await history.clear(threadId: entry.threadId)
            removed.append(entry.threadId)
        }
        return removed
    }
}
