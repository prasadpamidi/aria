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
