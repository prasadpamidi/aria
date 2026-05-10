import Foundation
import XCTest
@testable import Aria

final class InMemoryChatHistoryTests: XCTestCase {
    func testAppendAndFetchPreservesOrder() async throws {
        let history = InMemoryChatHistory()
        try await history.append(.user("hi"), threadId: "t1")
        try await history.append(.assistant("hello"), threadId: "t1")
        try await history.append(.user("how are you?"), threadId: "t1")

        let messages = try await history.messages(threadId: "t1")
        XCTAssertEqual(messages.map(\.textContent), ["hi", "hello", "how are you?"])
    }

    func testThreadsAreIsolated() async throws {
        let history = InMemoryChatHistory()
        try await history.append(.user("alpha"), threadId: "a")
        try await history.append(.user("beta"), threadId: "b")

        let threadA = try await history.messages(threadId: "a")
        let threadB = try await history.messages(threadId: "b")

        XCTAssertEqual(threadA.map(\.textContent), ["alpha"])
        XCTAssertEqual(threadB.map(\.textContent), ["beta"])
    }

    func testLimitReturnsLastN() async throws {
        let history = InMemoryChatHistory()
        for index in 0..<5 {
            try await history.append(.user("msg \(index)"), threadId: "t")
        }
        let last3 = try await history.messages(threadId: "t", limit: 3, before: nil)
        XCTAssertEqual(last3.map(\.textContent), ["msg 2", "msg 3", "msg 4"])
    }

    func testBeforeFiltersByCreatedAt() async throws {
        let history = InMemoryChatHistory()
        let earlier = Message(role: .user, content: [.text("early")], createdAt: Date(timeIntervalSince1970: 100))
        let later = Message(role: .user, content: [.text("late")], createdAt: Date(timeIntervalSince1970: 200))
        try await history.append(earlier, threadId: "t")
        try await history.append(later, threadId: "t")

        let before150 = try await history.messages(
            threadId: "t",
            limit: nil,
            before: Date(timeIntervalSince1970: 150)
        )
        XCTAssertEqual(before150.map(\.textContent), ["early"])
    }

    func testClearEmptiesThreadButLeavesOthers() async throws {
        let history = InMemoryChatHistory()
        try await history.append(.user("a"), threadId: "t1")
        try await history.append(.user("b"), threadId: "t2")
        try await history.clear(threadId: "t1")

        let t1 = try await history.messages(threadId: "t1")
        let t2 = try await history.messages(threadId: "t2")
        XCTAssertTrue(t1.isEmpty)
        XCTAssertEqual(t2.map(\.textContent), ["b"])
    }

    func testThreadsListsOnlyKnownIds() async throws {
        let history = InMemoryChatHistory()
        try await history.append(.user("x"), threadId: "alpha")
        try await history.append(.user("y"), threadId: "beta")

        let threads = try await history.threads()
        XCTAssertEqual(Set(threads), Set(["alpha", "beta"]))
    }

    func testAppendAllAddsBatch() async throws {
        let history = InMemoryChatHistory()
        try await history.appendAll(
            [.user("one"), .assistant("two"), .user("three")],
            threadId: "t"
        )
        let messages = try await history.messages(threadId: "t")
        XCTAssertEqual(messages.count, 3)
    }
}
