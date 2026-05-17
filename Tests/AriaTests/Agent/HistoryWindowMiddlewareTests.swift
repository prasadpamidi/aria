import Foundation
import XCTest
@testable import Aria

final class HistoryWindowMiddlewareTests: XCTestCase {
    // MARK: - No-op cases

    func testWindowIsNoOpWhenBothLimitsAreNil() {
        // Without either cap configured the middleware must pass the
        // message list through untouched — opting in is explicit.
        let messages = (0..<20).map { Message.user("msg-\($0)") }
        let out = HistoryWindowMiddleware.window(
            messages: messages,
            maxTurns: nil,
            maxTokens: nil,
            tokenCounter: { _ in 1 }
        )
        XCTAssertEqual(out.count, messages.count)
    }

    func testWindowIsNoOpWhenUnderBothCaps() {
        let messages = (0..<4).map { Message.user("m-\($0)") }
        let out = HistoryWindowMiddleware.window(
            messages: messages,
            maxTurns: 8,
            maxTokens: 1000,
            tokenCounter: { _ in 10 }
        )
        XCTAssertEqual(out.count, 4)
    }

    // MARK: - Turn-count cap

    func testWindowCapsToMaxTurnsKeepingMostRecent() {
        let messages = (0..<10).map { Message.user("m-\($0)") }
        let out = HistoryWindowMiddleware.window(
            messages: messages,
            maxTurns: 3,
            maxTokens: nil,
            tokenCounter: { _ in 1 }
        )
        XCTAssertEqual(out.count, 3)
        XCTAssertEqual(out.map(\.textContent), ["m-7", "m-8", "m-9"])
    }

    func testSystemMessagesAreAlwaysPreservedAboveTheTurnCap() {
        let system = Message.system("you are helpful")
        let tail = (0..<10).map { Message.user("m-\($0)") }
        let out = HistoryWindowMiddleware.window(
            messages: [system] + tail,
            maxTurns: 3,
            maxTokens: nil,
            tokenCounter: { _ in 1 }
        )
        // System survives + last 3 tail messages, in order.
        XCTAssertEqual(out.count, 4)
        XCTAssertEqual(out[0].role, .system)
        XCTAssertEqual(out[0].textContent, "you are helpful")
        XCTAssertEqual(out.dropFirst().map(\.textContent), ["m-7", "m-8", "m-9"])
    }

    func testMultipleSystemMessagesAreAllPreserved() {
        // Both initial system + a mid-stream injected system (e.g.
        // RAG-recall prepended on a later step) survive.
        let s1 = Message.system("base instructions")
        let s2 = Message.system("recalled facts")
        let tail = (0..<5).map { Message.user("m-\($0)") }
        let out = HistoryWindowMiddleware.window(
            messages: [s1, s2] + tail,
            maxTurns: 2,
            maxTokens: nil,
            tokenCounter: { _ in 1 }
        )
        XCTAssertEqual(out.count, 4)
        XCTAssertEqual(out[0].textContent, "base instructions")
        XCTAssertEqual(out[1].textContent, "recalled facts")
        XCTAssertEqual(out.suffix(2).map(\.textContent), ["m-3", "m-4"])
    }

    // MARK: - Token-budget cap

    func testWindowCapsToMaxTokensDroppingOldestFirst() {
        // 10 messages × 10 tokens each = 100 tokens. Budget = 35, so
        // only the last 3 tail messages survive.
        let messages = (0..<10).map { Message.user("m-\($0)") }
        let out = HistoryWindowMiddleware.window(
            messages: messages,
            maxTurns: nil,
            maxTokens: 35,
            tokenCounter: { _ in 10 }
        )
        XCTAssertEqual(out.map(\.textContent), ["m-7", "m-8", "m-9"])
    }

    func testTokenBudgetSubtractsSystemTokensFirst() {
        // System eats 30 of the 35-token budget — only 5 left for
        // the tail, so only the last 1-token message survives.
        let system = Message.system("S") // counted as 30
        let tail = (0..<5).map { Message.user("m-\($0)") } // each 10
        let counter: (Message) -> Int = { message in message.role == .system ? 30 : 10 }
        let out = HistoryWindowMiddleware.window(
            messages: [system] + tail,
            maxTurns: nil,
            maxTokens: 35,
            tokenCounter: counter
        )
        // Budget 35 = 30 (system) + 5 budget for tail. One 10-token
        // tail message doesn't fit, but the floor ("always keep one")
        // forces us to keep `m-4`. So total tokens may exceed budget.
        XCTAssertEqual(out.map(\.textContent), ["S", "m-4"])
    }

    func testTokenBudgetKeepsAtLeastOneTailMessageEvenIfOverBudget() {
        // Budget is impossibly tight (1 token); the middleware must
        // still leave one tail message — providers need something to
        // respond to. Tail messages dropped from the front, but the
        // last one always survives.
        let tail = (0..<3).map { Message.user("m-\($0)") }
        let out = HistoryWindowMiddleware.window(
            messages: tail,
            maxTurns: nil,
            maxTokens: 1,
            tokenCounter: { _ in 100 }
        )
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].textContent, "m-2")
    }

    // MARK: - Cap composition

    func testTurnCapAppliesBeforeTokenCap() {
        // 10 messages, each 100 tokens. maxTurns=5 drops first 5,
        // then maxTokens=300 drops 2 more from the resulting tail
        // (each 100 tokens), leaving 3.
        let messages = (0..<10).map { Message.user("m-\($0)") }
        let out = HistoryWindowMiddleware.window(
            messages: messages,
            maxTurns: 5,
            maxTokens: 300,
            tokenCounter: { _ in 100 }
        )
        XCTAssertEqual(out.map(\.textContent), ["m-7", "m-8", "m-9"])
    }

    // MARK: - Default token counter

    func testDefaultTokenCounterApproximatesFourCharsPerToken() async throws {
        // A 1000-char message ~ 250 tokens via the default heuristic.
        // Budget = 100 → must drop, leaving only the most-recent.
        let messages = [
            Message.user(String(repeating: "x", count: 1000)),
            Message.user("short")
        ]
        let middleware = HistoryWindowMiddleware(maxTurns: nil, maxTokens: 100)
        let state = AgentState(threadId: "t", messages: messages)
        let trimmed = try await middleware.beforeStep(state)
        // "short" (5 chars / 4 = 1 token) fits. The 1000-char message
        // (~250 tokens) doesn't — gets dropped.
        XCTAssertEqual(trimmed.messages.count, 1)
        XCTAssertEqual(trimmed.messages[0].textContent, "short")
    }

    // MARK: - beforeStep integration

    func testBeforeStepReturnsOriginalStateWhenNothingTrimmed() async throws {
        let messages = [Message.user("hi")]
        let middleware = HistoryWindowMiddleware(maxTurns: 10, maxTokens: 1000)
        let state = AgentState(threadId: "t", messages: messages)
        let result = try await middleware.beforeStep(state)
        XCTAssertEqual(result.messages.count, 1)
    }

    func testBeforeStepReplacesMessagesWhenTrimmed() async throws {
        let messages = (0..<5).map { Message.user("m-\($0)") }
        let middleware = HistoryWindowMiddleware(maxTurns: 2)
        let state = AgentState(threadId: "t", messages: messages)
        let result = try await middleware.beforeStep(state)
        XCTAssertEqual(result.messages.map(\.textContent), ["m-3", "m-4"])
        // Other state fields are preserved.
        XCTAssertEqual(result.threadId, "t")
    }
}
