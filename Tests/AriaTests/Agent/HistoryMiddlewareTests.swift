import Foundation
import XCTest
@testable import Aria
@testable import AriaTesting

final class HistoryMiddlewareTests: XCTestCase {
    func testPersistsAllMessagesOnFreshRun() async throws {
        let history = InMemoryChatHistory()
        let middleware = HistoryMiddleware(history: history)

        // Fresh thread — beforeRun finds nothing in storage, so the
        // baseline is 0; every message added during the run gets
        // persisted on afterStep.
        var state = AgentState(threadId: "t1", messages: [.user("hi")])
        state = try await middleware.beforeRun(state)
        state.messages.append(.assistant("hello"))
        state = try await middleware.afterStep(state)

        var stored = try await history.messages(threadId: "t1")
        XCTAssertEqual(stored.map(\.textContent), ["hi", "hello"])

        // Subsequent step: only the newly-appended message is persisted.
        state.messages.append(.assistant("more"))
        state = try await middleware.afterStep(state)

        stored = try await history.messages(threadId: "t1")
        XCTAssertEqual(stored.map(\.textContent), ["hi", "hello", "more"])
    }

    func testLoadsExistingHistoryAndDoesNotRepersistIt() async throws {
        let history = InMemoryChatHistory()
        try await history.append(.user("from earlier"), threadId: "t1")
        try await history.append(.assistant("from earlier reply"), threadId: "t1")

        let middleware = HistoryMiddleware(history: history)

        // State arrives with just the new user message; beforeRun should
        // prepend the persisted history for context.
        var state = AgentState(threadId: "t1", messages: [.user("new turn")])
        state = try await middleware.beforeRun(state)
        XCTAssertEqual(state.messages.map(\.textContent), [
            "from earlier",
            "from earlier reply",
            "new turn"
        ])

        state.messages.append(.assistant("new reply"))
        state = try await middleware.afterStep(state)

        let stored = try await history.messages(threadId: "t1")
        XCTAssertEqual(stored.map(\.textContent), [
            "from earlier",
            "from earlier reply",
            "new turn",
            "new reply"
        ])
    }

    func testThreadsAreTrackedIndependently() async throws {
        let history = InMemoryChatHistory()
        let middleware = HistoryMiddleware(history: history)

        var stateA = AgentState(threadId: "a")
        stateA = try await middleware.beforeRun(stateA)
        stateA.messages.append(.user("a-msg"))
        _ = try await middleware.afterStep(stateA)

        var stateB = AgentState(threadId: "b")
        stateB = try await middleware.beforeRun(stateB)
        stateB.messages.append(.user("b-msg"))
        _ = try await middleware.afterStep(stateB)

        let aStored = try await history.messages(threadId: "a")
        let bStored = try await history.messages(threadId: "b")
        XCTAssertEqual(aStored.map(\.textContent), ["a-msg"])
        XCTAssertEqual(bStored.map(\.textContent), ["b-msg"])
    }

    func testMiddlewareWiresIntoAgentLoop() async throws {
        let history = InMemoryChatHistory()
        let provider = MockLLMProvider(scenes: [.text("Hello!")])
        let agent = Agent(config: AgentConfig(
            provider: provider,
            threadId: "demo",
            middleware: [HistoryMiddleware(history: history)]
        ))

        for try await _ in agent.stream(.message(.user("Hi"))) { }

        let stored = try await history.messages(threadId: "demo")
        XCTAssertEqual(stored.count, 2)
        XCTAssertEqual(stored[0].role, .user)
        XCTAssertEqual(stored[0].textContent, "Hi")
        XCTAssertEqual(stored[1].role, .assistant)
        XCTAssertEqual(stored[1].textContent, "Hello!")
    }
}
