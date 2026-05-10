import Foundation
import XCTest
@testable import Aria
@testable import AriaTesting

final class RAGMiddlewareTests: XCTestCase {
    func makeMemoryStore() -> DefaultMemoryStore {
        let embedder = HashEmbedder(dimensions: 64)
        let vectorStore = InMemoryVectorStore(dimensions: embedder.dimensions)
        return DefaultMemoryStore(embedder: embedder, store: vectorStore)
    }

    func testInjectsRecalledContextBeforeFirstStep() async throws {
        let memory = self.makeMemoryStore()
        try await memory.remember(
            MemoryItem(content: "user prefers metric units"),
            namespace: ["t"]
        )

        let middleware = RAGMiddleware(memoryStore: memory, namespace: ["t"], topK: 4)
        var state = AgentState(
            threadId: "t",
            messages: [.user("what units does the user prefer?")]
        )
        state = try await middleware.beforeStep(state)

        XCTAssertEqual(state.messages.count, 2, "system context should be inserted")
        let systemMessage = state.messages.first { $0.role == .system }
        XCTAssertNotNil(systemMessage)
        XCTAssertTrue(
            systemMessage?.textContent.contains("metric units") ?? false,
            "Recalled fact should appear in the injected context"
        )
    }

    func testOnRecallFiresWithMatchedItems() async throws {
        let memory = self.makeMemoryStore()
        try await memory.remember(
            MemoryItem(content: "user prefers metric units"),
            namespace: ["t"]
        )
        try await memory.remember(
            MemoryItem(content: "user is vegetarian"),
            namespace: ["t"]
        )

        // Use an actor to capture the recalled items synchronously
        // across the @Sendable closure boundary.
        actor Recorder {
            private(set) var recalled: [String] = []
            func record(_ items: [String]) {
                self.recalled = items
            }
        }
        let recorder = Recorder()

        let middleware = RAGMiddleware(
            memoryStore: memory,
            namespace: ["t"],
            topK: 4,
            onRecall: { matches in
                let texts = matches.map(\.item.content)
                Task { await recorder.record(texts) }
            }
        )
        var state = AgentState(threadId: "t", messages: [.user("user preferences?")])
        state = try await middleware.beforeStep(state)
        // The closure dispatches into a Task; give it a tick to settle.
        try await Task.sleep(for: .milliseconds(50))
        let captured = await recorder.recalled
        XCTAssertFalse(captured.isEmpty, "onRecall should have fired with matches")
    }

    func testSkipsInjectionWhenNoMemoriesMatch() async throws {
        let memory = self.makeMemoryStore()
        // Empty store
        let middleware = RAGMiddleware(memoryStore: memory, namespace: ["t"], topK: 4)
        var state = AgentState(threadId: "t", messages: [.user("anything?")])
        state = try await middleware.beforeStep(state)
        XCTAssertEqual(state.messages.count, 1)
    }

    func testSkipsAfterFirstStep() async throws {
        let memory = self.makeMemoryStore()
        try await memory.remember(
            MemoryItem(content: "loud fact"),
            namespace: ["t"]
        )

        let middleware = RAGMiddleware(memoryStore: memory, namespace: ["t"], topK: 4)
        var state = AgentState(threadId: "t", messages: [.user("loud fact?")])
        state.stepCount = 1 // pretend we're past the first step

        state = try await middleware.beforeStep(state)
        XCTAssertEqual(state.messages.count, 1, "no injection after step 0")
    }

    func testInjectionIsNamespaceScoped() async throws {
        let memory = self.makeMemoryStore()
        try await memory.remember(
            MemoryItem(content: "namespace-A fact"),
            namespace: ["a"]
        )
        try await memory.remember(
            MemoryItem(content: "namespace-B fact"),
            namespace: ["b"]
        )

        // Middleware scoped to namespace `a` should not surface `b`'s entries.
        let middleware = RAGMiddleware(memoryStore: memory, namespace: ["a"], topK: 4)
        var state = AgentState(threadId: "t", messages: [.user("any fact")])
        state = try await middleware.beforeStep(state)

        let systemMessage = state.messages.first { $0.role == .system }
        XCTAssertTrue(systemMessage?.textContent.contains("namespace-A") ?? false)
        XCTAssertFalse(systemMessage?.textContent.contains("namespace-B") ?? false)
    }
}
