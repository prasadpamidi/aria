import Foundation
import XCTest
@testable import Aria

/// Tests-first specification of `HistoryRetentionPolicy.enforce(on:)`.
///
/// The policy bounds disk growth of `ChatHistory` stores by clearing
/// entire threads that exceed configured limits. Per-thread message
/// truncation (drop oldest N from a thread) would need a protocol
/// extension and is intentionally out of scope here — whole-thread
/// eviction is enough to cap disk, and threads are the natural unit
/// of "abandoned conversation" expiry.
final class HistoryRetentionPolicyTests: XCTestCase {
    // MARK: Internal

    // MARK: - No-op cases

    func testEnforceIsNoOpWhenNoLimitsConfigured() async throws {
        let history = try await self.makeHistory(populated: [
            ThreadSpec(threadId: "a", ageDays: 100, count: 1),
            ThreadSpec(threadId: "b", ageDays: 30, count: 1),
            ThreadSpec(threadId: "c", ageDays: 5, count: 1)
        ])
        let policy = HistoryRetentionPolicy()
        _ = try await policy.enforce(on: history)
        let threads = try await history.threads()
        XCTAssertEqual(Set(threads), ["a", "b", "c"])
    }

    func testEnforceIsNoOpWhenAllThreadsAreWithinAgeAndCountLimits() async throws {
        let history = try await self.makeHistory(populated: [
            ThreadSpec(threadId: "a", ageDays: 5, count: 1),
            ThreadSpec(threadId: "b", ageDays: 10, count: 1)
        ])
        let policy = HistoryRetentionPolicy(maxThreadAgeDays: 30, maxThreadCount: 10)
        _ = try await policy.enforce(on: history)
        let threads = try await history.threads()
        XCTAssertEqual(Set(threads), ["a", "b"])
    }

    // MARK: - Age-based eviction

    func testEnforceDropsThreadsOlderThanMaxAgeDays() async throws {
        let history = try await self.makeHistory(populated: [
            ThreadSpec(threadId: "fresh", ageDays: 5, count: 1),
            ThreadSpec(threadId: "aging", ageDays: 29, count: 1),
            ThreadSpec(threadId: "ancient", ageDays: 200, count: 1)
        ])
        let policy = HistoryRetentionPolicy(maxThreadAgeDays: 30)
        let report = try await policy.enforce(on: history)
        let threads = try await history.threads()
        XCTAssertEqual(Set(threads), ["fresh", "aging"])
        XCTAssertEqual(report.threadsRemovedForAge, ["ancient"])
    }

    func testAgeIsMeasuredAgainstNewestMessageInThread() async throws {
        // A thread with an old first message but a recent latest
        // message should NOT be evicted — "thread age" is "last
        // activity" not "first message".
        let history = InMemoryChatHistory()
        let now = Date()
        let old = Message(
            role: .user,
            content: [.text("old")],
            metadata: [:],
            createdAt: now.addingTimeInterval(-200 * 86400)
        )
        let recent = Message(
            role: .user,
            content: [.text("recent")],
            metadata: [:],
            createdAt: now.addingTimeInterval(-2 * 86400)
        )
        try await history.appendAll([old, recent], threadId: "long-running")
        let policy = HistoryRetentionPolicy(maxThreadAgeDays: 30)
        _ = try await policy.enforce(on: history)
        let threads = try await history.threads()
        XCTAssertEqual(Set(threads), ["long-running"])
    }

    // MARK: - Count-based eviction

    func testEnforceDropsOldestThreadsWhenOverMaxThreadCount() async throws {
        let history = try await self.makeHistory(populated: [
            ThreadSpec(threadId: "a", ageDays: 30, count: 1),
            ThreadSpec(threadId: "b", ageDays: 20, count: 1),
            ThreadSpec(threadId: "c", ageDays: 10, count: 1),
            ThreadSpec(threadId: "d", ageDays: 5, count: 1)
        ])
        let policy = HistoryRetentionPolicy(maxThreadCount: 2)
        let report = try await policy.enforce(on: history)
        let threads = try await history.threads()
        XCTAssertEqual(Set(threads), ["c", "d"])
        XCTAssertEqual(Set(report.threadsRemovedForCount), ["a", "b"])
    }

    // MARK: - Composition

    func testAgeEvictionRunsBeforeCountEviction() async throws {
        // After age drops "ancient", we have 3 threads (a, b, c).
        // maxThreadCount=2 should then drop the oldest of those (b).
        // Net survivors: c, fresh.
        let history = try await self.makeHistory(populated: [
            ThreadSpec(threadId: "ancient", ageDays: 200, count: 1),
            ThreadSpec(threadId: "a", ageDays: 25, count: 1),
            ThreadSpec(threadId: "b", ageDays: 10, count: 1),
            ThreadSpec(threadId: "c", ageDays: 3, count: 1)
        ])
        let policy = HistoryRetentionPolicy(maxThreadAgeDays: 30, maxThreadCount: 2)
        let report = try await policy.enforce(on: history)
        let threads = try await history.threads()
        XCTAssertEqual(Set(threads), ["b", "c"])
        XCTAssertEqual(report.threadsRemovedForAge, ["ancient"])
        XCTAssertEqual(Set(report.threadsRemovedForCount), ["a"])
    }

    func testEnforceIsIdempotent() async throws {
        let history = try await self.makeHistory(populated: [
            ThreadSpec(threadId: "a", ageDays: 200, count: 1),
            ThreadSpec(threadId: "b", ageDays: 5, count: 1)
        ])
        let policy = HistoryRetentionPolicy(maxThreadAgeDays: 30)
        let firstReport = try await policy.enforce(on: history)
        let secondReport = try await policy.enforce(on: history)
        // Second pass evicts nothing — already pruned.
        XCTAssertEqual(firstReport.threadsRemovedForAge, ["a"])
        XCTAssertEqual(secondReport.threadsRemovedForAge, [])
        let threads = try await history.threads()
        XCTAssertEqual(threads, ["b"])
    }

    // MARK: - Edge cases

    func testEnforceHandlesEmptyHistoryStore() async throws {
        let history = InMemoryChatHistory()
        let policy = HistoryRetentionPolicy(maxThreadAgeDays: 30, maxThreadCount: 5)
        let report = try await policy.enforce(on: history)
        XCTAssertTrue(report.threadsRemovedForAge.isEmpty)
        XCTAssertTrue(report.threadsRemovedForCount.isEmpty)
    }

    func testEnforceSkipsThreadsWithNoMessages() async throws {
        // A thread that exists in `threads()` but has 0 messages
        // (corner case after a prior `clear`) shouldn't crash or
        // count toward limits.
        let history = InMemoryChatHistory()
        try await history.append(Message.user("hi"), threadId: "a")
        try await history.clear(threadId: "a")
        let policy = HistoryRetentionPolicy(maxThreadAgeDays: 30)
        let report = try await policy.enforce(on: history)
        XCTAssertTrue(report.threadsRemovedForAge.isEmpty)
    }

    // MARK: Private

    // MARK: - Builders

    /// Spec for one populated thread — used by `makeHistory(populated:)`
    /// to set up determinisitcally-aged threads.
    private struct ThreadSpec {
        let threadId: String
        let ageDays: Double
        let count: Int
    }

    private func makeHistory(populated: [ThreadSpec]) async throws -> InMemoryChatHistory {
        let history = InMemoryChatHistory()
        let now = Date()
        for entry in populated {
            let createdAt = now.addingTimeInterval(-entry.ageDays * 86400)
            let messages = (0..<entry.count).map { i in
                Message.user("\(entry.threadId)-msg-\(i)", metadata: [:])
            }
            // `Message.user(_:)` stamps `createdAt = Date()`; we need
            // deterministic ages, so reconstruct each message manually.
            let timed = messages.map { msg in
                Message(role: msg.role, content: msg.content, metadata: msg.metadata, createdAt: createdAt)
            }
            try await history.appendAll(timed, threadId: entry.threadId)
        }
        return history
    }
}
