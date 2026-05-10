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
