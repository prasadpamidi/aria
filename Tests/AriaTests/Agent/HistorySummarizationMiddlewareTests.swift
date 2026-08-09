import Foundation
import XCTest
@testable import Aria

/// Tests-first spec for `HistorySummarizationMiddleware`.
///
/// The middleware compresses the older portion of the history into a
/// single system message when the message count exceeds a trigger
/// threshold, preserving the most recent turns verbatim. This lets a
/// long-running conversation thread keep its *gist* without sending
/// the entire raw transcript on every turn.
final class HistorySummarizationMiddlewareTests: XCTestCase {
    // MARK: Internal

    // MARK: - No-op cases

    func testIsNoOpWhenMessageCountIsBelowTrigger() async throws {
        let summarizer = RecordingSummarizer()
        let middleware = self.makeMiddleware(
            summarizer: summarizer,
            triggerAfterTurns: 10,
            keepRecentTurns: 4
        )
        let messages = (0..<8).map { Message.user("m-\($0)") }
        let state = AgentState(threadId: "t", messages: messages)
        let out = try await middleware.beforeStep(state)
        XCTAssertEqual(out.messages.count, 8)
        XCTAssertEqual(out.messages, messages)
        let calls = await summarizer.invocations.count
        XCTAssertEqual(calls, 0)
    }

    func testIsNoOpWhenMessageCountEqualsTriggerExactly() async throws {
        // Trigger means "after this many turns" — equality is the
        // boundary; should not fire until strictly greater.
        let summarizer = RecordingSummarizer()
        let middleware = self.makeMiddleware(
            summarizer: summarizer,
            triggerAfterTurns: 5,
            keepRecentTurns: 2
        )
        let messages = (0..<5).map { Message.user("m-\($0)") }
        let state = AgentState(threadId: "t", messages: messages)
        let out = try await middleware.beforeStep(state)
        XCTAssertEqual(out.messages.count, 5)
        let calls = await summarizer.invocations.count
        XCTAssertEqual(calls, 0)
    }

    // MARK: - Compaction

    func testCompactsOlderTurnsIntoOneSystemSummaryWhenOverTrigger() async throws {
        let summarizer = RecordingSummarizer(summary: "the user is vegetarian and lifts 4x/wk")
        let middleware = self.makeMiddleware(
            summarizer: summarizer,
            triggerAfterTurns: 6,
            keepRecentTurns: 2
        )
        let messages = (0..<10).map { Message.user("m-\($0)") }
        let state = AgentState(threadId: "t", messages: messages)
        let out = try await middleware.beforeStep(state)

        // Expected layout: [summary, m-8, m-9] (1 summary + 2 recent).
        XCTAssertEqual(out.messages.count, 3)
        XCTAssertEqual(out.messages[0].role, .system)
        XCTAssertTrue(out.messages[0].textContent.contains("the user is vegetarian"))
        XCTAssertEqual(out.messages[1].textContent, "m-8")
        XCTAssertEqual(out.messages[2].textContent, "m-9")
    }

    func testSummarizerReceivesOnlyTheOlderSliceAndNoSystemMessages() async throws {
        let summarizer = RecordingSummarizer()
        let middleware = self.makeMiddleware(
            summarizer: summarizer,
            triggerAfterTurns: 5,
            keepRecentTurns: 2
        )
        let messages = [
            Message.system("base instructions"),
            Message.user("m-0"),
            Message.user("m-1"),
            Message.user("m-2"),
            Message.user("m-3"),
            Message.user("m-4"),
            Message.user("m-5")
        ]
        let state = AgentState(threadId: "t", messages: messages)
        _ = try await middleware.beforeStep(state)

        let invocations = await summarizer.invocations
        XCTAssertEqual(invocations.count, 1)
        // The summarizer should see only the OLDER non-system turns
        // (m-0 .. m-3) — not the recent two (m-4, m-5) or any system
        // messages.
        XCTAssertEqual(invocations[0].map(\.textContent), ["m-0", "m-1", "m-2", "m-3"])
        XCTAssertTrue(invocations[0].allSatisfy { $0.role != .system })
    }

    func testPreservesPreExistingSystemMessagesAboveTheSummary() async throws {
        let summarizer = RecordingSummarizer(summary: "compressed older convo")
        let middleware = self.makeMiddleware(
            summarizer: summarizer,
            triggerAfterTurns: 4,
            keepRecentTurns: 2
        )
        let s1 = Message.system("base instructions")
        let s2 = Message.system("recalled facts")
        let tail = (0..<6).map { Message.user("m-\($0)") }
        let state = AgentState(threadId: "t", messages: [s1, s2] + tail)
        let out = try await middleware.beforeStep(state)

        // [s1, s2, summary, m-4, m-5]
        XCTAssertEqual(out.messages.count, 5)
        XCTAssertEqual(out.messages[0].textContent, "base instructions")
        XCTAssertEqual(out.messages[1].textContent, "recalled facts")
        XCTAssertEqual(out.messages[2].role, .system)
        XCTAssertTrue(out.messages[2].textContent.contains("compressed older convo"))
        XCTAssertEqual(out.messages[3].textContent, "m-4")
        XCTAssertEqual(out.messages[4].textContent, "m-5")
    }

    // MARK: - Edge cases

    func testGracefulFallthroughWhenSummarizerThrows() async throws {
        // If the summarizer fails (network down, rate limit, etc.) the
        // middleware must leave state untouched — losing the turn over
        // a summarization failure is worse than sending a long prompt.
        let summarizer = RecordingSummarizer(shouldThrow: true)
        let middleware = self.makeMiddleware(
            summarizer: summarizer,
            triggerAfterTurns: 3,
            keepRecentTurns: 1
        )
        let messages = (0..<6).map { Message.user("m-\($0)") }
        let state = AgentState(threadId: "t", messages: messages)
        let out = try await middleware.beforeStep(state)
        // Untouched.
        XCTAssertEqual(out.messages.count, 6)
        XCTAssertEqual(out.messages.map(\.textContent), ["m-0", "m-1", "m-2", "m-3", "m-4", "m-5"])
    }

    func testKeepRecentTurnsGreaterThanCountIsNoOp() async throws {
        // Configuration where keepRecent is larger than the non-system
        // count: nothing older to summarize, so no-op.
        let summarizer = RecordingSummarizer()
        let middleware = self.makeMiddleware(
            summarizer: summarizer,
            triggerAfterTurns: 2,
            keepRecentTurns: 10
        )
        let messages = (0..<5).map { Message.user("m-\($0)") }
        let state = AgentState(threadId: "t", messages: messages)
        let out = try await middleware.beforeStep(state)
        XCTAssertEqual(out.messages.count, 5)
        let calls = await summarizer.invocations.count
        XCTAssertEqual(calls, 0)
    }

    func testEmptyStateIsNoOp() async throws {
        let summarizer = RecordingSummarizer()
        let middleware = self.makeMiddleware(
            summarizer: summarizer,
            triggerAfterTurns: 5,
            keepRecentTurns: 2
        )
        let state = AgentState(threadId: "t", messages: [])
        let out = try await middleware.beforeStep(state)
        XCTAssertTrue(out.messages.isEmpty)
        let calls = await summarizer.invocations.count
        XCTAssertEqual(calls, 0)
    }

    func testOnlySystemMessagesIsNoOp() async throws {
        // System messages never count toward the trigger (they're
        // instructions, not history) and never get summarized.
        let summarizer = RecordingSummarizer()
        let middleware = self.makeMiddleware(
            summarizer: summarizer,
            triggerAfterTurns: 0,
            keepRecentTurns: 0
        )
        let systems = (0..<5).map { Message.system("s-\($0)") }
        let state = AgentState(threadId: "t", messages: systems)
        let out = try await middleware.beforeStep(state)
        XCTAssertEqual(out.messages.count, 5)
        let calls = await summarizer.invocations.count
        XCTAssertEqual(calls, 0)
    }

    // MARK: - Summary caching

    func testReusesCachedSummaryWhenOlderSliceUnchanged() async throws {
        // Two `beforeStep` calls in a row with the SAME older slice
        // should only invoke the summarizer once — the cached
        // summary is reused on the second call.
        let summarizer = RecordingSummarizer(summary: "compressed")
        let middleware = self.makeMiddleware(
            summarizer: summarizer,
            triggerAfterTurns: 3,
            keepRecentTurns: 1
        )
        let messages = (0..<5).map { Message.user("m-\($0)") }
        let state = AgentState(threadId: "t", messages: messages)
        _ = try await middleware.beforeStep(state)
        _ = try await middleware.beforeStep(state)
        let calls = await summarizer.invocations.count
        XCTAssertEqual(calls, 1, "expected cache hit on second beforeStep")
    }

    func testInvalidatesCacheWhenOlderSliceChanges() async throws {
        // Different older content → cache miss → re-summarize.
        let summarizer = RecordingSummarizer(summary: "compressed")
        let middleware = self.makeMiddleware(
            summarizer: summarizer,
            triggerAfterTurns: 3,
            keepRecentTurns: 1
        )
        let firstState = AgentState(
            threadId: "t",
            messages: (0..<5).map { Message.user("m-\($0)") }
        )
        let secondState = AgentState(
            threadId: "t",
            messages: (0..<5).map { Message.user("different-\($0)") }
        )
        _ = try await middleware.beforeStep(firstState)
        _ = try await middleware.beforeStep(secondState)
        let calls = await summarizer.invocations.count
        XCTAssertEqual(calls, 2)
    }

    func testCacheIsKeyedPerThreadId() async throws {
        // Two threads with identical older slices should each get
        // their own cache entry — a coach session's summary must
        // never leak into a recipe session.
        let summarizer = RecordingSummarizer(summary: "compressed")
        let middleware = self.makeMiddleware(
            summarizer: summarizer,
            triggerAfterTurns: 3,
            keepRecentTurns: 1
        )
        let messages = (0..<5).map { Message.user("m-\($0)") }
        let coachState = AgentState(threadId: "coach", messages: messages)
        let recipeState = AgentState(threadId: "recipe", messages: messages)
        _ = try await middleware.beforeStep(coachState)
        _ = try await middleware.beforeStep(recipeState)
        // Two different threadIds → two summarizer calls even though
        // the older slice text is identical.
        let calls = await summarizer.invocations.count
        XCTAssertEqual(calls, 2)
    }

    func testCachedSummaryProducesSameOutputAsRecomputed() async throws {
        // The reused-from-cache result must be byte-equivalent to
        // re-summarizing from scratch. Otherwise the state diverges
        // between the first and subsequent calls.
        let summarizer = RecordingSummarizer(summary: "exact summary text")
        let middleware = self.makeMiddleware(
            summarizer: summarizer,
            triggerAfterTurns: 3,
            keepRecentTurns: 1
        )
        let state = AgentState(
            threadId: "t",
            messages: (0..<5).map { Message.user("m-\($0)") }
        )
        let first = try await middleware.beforeStep(state)
        let second = try await middleware.beforeStep(state)
        XCTAssertEqual(first.messages, second.messages)
    }

    // MARK: - State preservation

    func testPreservesOtherStateFields() async throws {
        let summarizer = RecordingSummarizer()
        let middleware = self.makeMiddleware(
            summarizer: summarizer,
            triggerAfterTurns: 3,
            keepRecentTurns: 1
        )
        let messages = (0..<6).map { Message.user("m-\($0)") }
        let state = AgentState(threadId: "specific-thread", messages: messages)
        let out = try await middleware.beforeStep(state)
        XCTAssertEqual(out.threadId, "specific-thread")
    }

    // MARK: Private

    // MARK: - Test helpers

    /// Records each summarizer invocation so tests can assert on what
    /// slice the middleware passed in.
    private actor RecordingSummarizer {
        // MARK: Lifecycle

        init(summary: String = "earlier convo summary", shouldThrow: Bool = false) {
            self.fixedSummary = summary
            self.shouldThrow = shouldThrow
        }

        // MARK: Internal

        private(set) var invocations: [[Message]] = []

        func summarize(_ messages: [Message]) async throws -> String {
            self.invocations.append(messages)
            if self.shouldThrow {
                throw NSError(domain: "test.summarizer", code: 1)
            }
            return self.fixedSummary
        }

        // MARK: Private

        private let fixedSummary: String
        private let shouldThrow: Bool
    }

    private func makeMiddleware(
        summarizer: RecordingSummarizer,
        triggerAfterTurns: Int,
        keepRecentTurns: Int
    ) -> HistorySummarizationMiddleware {
        HistorySummarizationMiddleware(
            triggerAfterTurns: triggerAfterTurns,
            keepRecentTurns: keepRecentTurns,
            summarizer: { messages in
                try await summarizer.summarize(messages)
            }
        )
    }
}

// MARK: - SizeTriggerTests

/// Counting messages measures the wrong thing.
///
/// A thinking model puts hundreds of tokens of working-out into one
/// assistant turn, so a handful of "recent" messages can fill most of a
/// 4,096-token window while sitting far under any turn threshold. Seen
/// in the field at 94% utilisation after five short exchanges, with
/// compaction never firing.
final class SizeTriggerTests: XCTestCase {
    func testLargeHistoryCompactsBelowTheTurnThreshold() async throws {
        let middleware = HistorySummarizationMiddleware(
            triggerAfterTurns: 100,
            keepRecentTurns: 2,
            triggerAfterCharacters: 2000,
            summarizer: { _ in "SUMMARY" }
        )
        let bulky = String(repeating: "deliberating ", count: 200)
        let state = AgentState(messages: [
            .user("one"), .assistant(bulky),
            .user("two"), .assistant(bulky),
        ])

        let result = try await middleware.beforeStep(state)

        XCTAssertTrue(
            result.messages.contains { $0.role == .system && $0.textContent.contains("SUMMARY") },
            "Four messages is far under the turn threshold, but the text is not"
        )
    }

    /// The size trigger must not fire on ordinary short conversations.
    func testSmallHistoryIsLeftAlone() async throws {
        let middleware = HistorySummarizationMiddleware(
            triggerAfterTurns: 100,
            keepRecentTurns: 2,
            triggerAfterCharacters: 2000,
            summarizer: { _ in "SUMMARY" }
        )
        let state = AgentState(messages: [
            .user("hello"), .assistant("hi"),
            .user("thanks"), .assistant("welcome"),
        ])

        let result = try await middleware.beforeStep(state)

        XCTAssertFalse(result.messages.contains { $0.textContent.contains("SUMMARY") })
    }

    /// Passing `nil` restores pure count-based behaviour.
    func testSizeTriggerCanBeDisabled() async throws {
        let middleware = HistorySummarizationMiddleware(
            triggerAfterTurns: 100,
            keepRecentTurns: 2,
            triggerAfterCharacters: nil,
            summarizer: { _ in "SUMMARY" }
        )
        let bulky = String(repeating: "deliberating ", count: 500)
        let state = AgentState(messages: [
            .user("one"), .assistant(bulky),
            .user("two"), .assistant(bulky),
        ])

        let result = try await middleware.beforeStep(state)

        XCTAssertFalse(result.messages.contains { $0.textContent.contains("SUMMARY") })
    }
}
