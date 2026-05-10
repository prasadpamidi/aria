#if canImport(Foundation) && (os(iOS) || os(macOS) || os(watchOS) || os(tvOS) || os(visionOS))

    import Foundation
    import XCTest
    @testable import Aria
    @testable import AriaApple

    final class GRDBChatHistoryTests: XCTestCase {
        func testInMemoryStorageAppendsAndReadsBack() async throws {
            let storage = try GRDBStorage()
            let history = storage.chatHistory

            try await history.append(.user("hi"), threadId: "t")
            try await history.append(
                .assistant("hello", toolCalls: [
                    ToolCall(id: "c1", name: "echo", arguments: .object(["x": .integer(1)]))
                ]),
                threadId: "t"
            )

            let messages = try await history.messages(threadId: "t")
            XCTAssertEqual(messages.count, 2)
            XCTAssertEqual(messages[0].role, .user)
            XCTAssertEqual(messages[0].textContent, "hi")
            XCTAssertEqual(messages[1].role, .assistant)
            XCTAssertEqual(messages[1].toolCalls.first?.id, "c1")
            XCTAssertEqual(
                messages[1].toolCalls.first?.arguments,
                .object(["x": .integer(1)])
            )
        }

        func testFilePersistsAcrossInstances() async throws {
            let url = FileManager.default
                .temporaryDirectory
                .appendingPathComponent("aria-test-\(UUID().uuidString).sqlite")
            defer { try? FileManager.default.removeItem(at: url) }

            do {
                let storage = try GRDBStorage(url: url)
                try await storage.chatHistory.append(.user("persist me"), threadId: "t")
            }
            let storage = try GRDBStorage(url: url)
            let messages = try await storage.chatHistory.messages(threadId: "t")
            XCTAssertEqual(messages.map(\.textContent), ["persist me"])
        }

        func testLimitReturnsTailOfThread() async throws {
            let storage = try GRDBStorage()
            let history = storage.chatHistory

            for index in 0..<5 {
                try await history.append(.user("m\(index)"), threadId: "t")
            }

            let tail = try await history.messages(threadId: "t", limit: 2, before: nil)
            XCTAssertEqual(tail.map(\.textContent), ["m3", "m4"])
        }

        func testThreadsListsDistinctIds() async throws {
            let storage = try GRDBStorage()
            let history = storage.chatHistory

            try await history.append(.user("a"), threadId: "alpha")
            try await history.append(.user("b"), threadId: "beta")
            try await history.append(.user("a2"), threadId: "alpha")

            let threads = try await history.threads()
            XCTAssertEqual(Set(threads), Set(["alpha", "beta"]))
        }

        func testClearEmptiesOneThread() async throws {
            let storage = try GRDBStorage()
            let history = storage.chatHistory

            try await history.append(.user("a"), threadId: "alpha")
            try await history.append(.user("b"), threadId: "beta")
            try await history.clear(threadId: "alpha")

            let alpha = try await history.messages(threadId: "alpha")
            let beta = try await history.messages(threadId: "beta")
            XCTAssertTrue(alpha.isEmpty)
            XCTAssertEqual(beta.map(\.textContent), ["b"])
        }
    }

    final class GRDBCheckpointerTests: XCTestCase {
        func testRoundTripWithMetadata() async throws {
            let storage = try GRDBStorage()
            let cp = Checkpoint(
                id: "cp-1",
                threadId: "t",
                state: Data([0x01, 0x02, 0x03]),
                metadata: ["step": .integer(1), "note": .string("hello")]
            )
            try await storage.checkpointer.put(cp, threadId: "t")

            let fetched = try await storage.checkpointer.get(threadId: "t", checkpointId: "cp-1")
            XCTAssertEqual(fetched, cp)
        }

        func testLatestReturnsMostRecent() async throws {
            let storage = try GRDBStorage()
            let early = Checkpoint(
                id: "early",
                threadId: "t",
                createdAt: Date(timeIntervalSince1970: 100),
                state: Data()
            )
            let late = Checkpoint(
                id: "late",
                threadId: "t",
                createdAt: Date(timeIntervalSince1970: 200),
                state: Data()
            )
            try await storage.checkpointer.put(early, threadId: "t")
            try await storage.checkpointer.put(late, threadId: "t")

            let latest = try await storage.checkpointer.latest(threadId: "t")
            XCTAssertEqual(latest?.id, "late")
        }

        func testListNewestFirstWithLimit() async throws {
            let storage = try GRDBStorage()
            for index in 0..<5 {
                try await storage.checkpointer.put(
                    Checkpoint(
                        id: "cp-\(index)",
                        threadId: "t",
                        createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
                        state: Data()
                    ),
                    threadId: "t"
                )
            }

            let list = try await storage.checkpointer.list(threadId: "t", limit: 3)
            XCTAssertEqual(list.map(\.id), ["cp-4", "cp-3", "cp-2"])
        }

        func testDeleteThreadClearsAllCheckpoints() async throws {
            let storage = try GRDBStorage()
            try await storage.checkpointer.put(
                Checkpoint(threadId: "a", state: Data()),
                threadId: "a"
            )
            try await storage.checkpointer.put(
                Checkpoint(threadId: "b", state: Data()),
                threadId: "b"
            )
            try await storage.checkpointer.deleteThread("a")

            let aLatest = try await storage.checkpointer.latest(threadId: "a")
            let bLatest = try await storage.checkpointer.latest(threadId: "b")
            XCTAssertNil(aLatest)
            XCTAssertNotNil(bLatest)
        }
    }

#endif
