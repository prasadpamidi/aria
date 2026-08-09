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

// MARK: - RAGStalenessTests

/// Recall is per-turn context, not an instruction.
///
/// It was accumulating without limit: every turn inserted a fresh
/// block, and the assembler preserves system messages by design — it
/// cannot tell a recalled-memory block from instructions it must never
/// trim. One field trace carried "## Recalled memories" twice, the same
/// two facts in different orders. By turn ten there would have been ten.
final class RAGStalenessTests: XCTestCase {
    func testOnlyTheCurrentRecallBlockSurvives() async throws {
        let store = RAGMiddlewareTests().makeMemoryStore()
        try await store.remember(MemoryItem(content: "user lives in Berlin"), namespace: ["u"])
        let middleware = RAGMiddleware(
            memoryStore: store,
            namespace: ["u"],
            topK: 5,
            instructionPrefix: "## Recalled memories"
        )

        var state = AgentState(messages: [.user("where do I live?")])
        // Three turns through the same middleware.
        for _ in 0 ..< 3 {
            state = try await middleware.beforeStep(state)
        }

        let blocks = state.messages.count { message in
            message.role == .system && message.textContent.hasPrefix("## Recalled memories")
        }
        XCTAssertEqual(blocks, 1, "Each turn replaces its own block rather than stacking another")
    }

    /// System messages the middleware did not write are none of its
    /// business — dropping the caller's instructions would be a far
    /// worse bug than the one being fixed.
    func testUnrelatedSystemMessagesAreUntouched() async throws {
        let store = RAGMiddlewareTests().makeMemoryStore()
        try await store.remember(MemoryItem(content: "user lives in Berlin"), namespace: ["u"])
        let middleware = RAGMiddleware(
            memoryStore: store,
            namespace: ["u"],
            topK: 5,
            instructionPrefix: "## Recalled memories"
        )

        let state = try await middleware.beforeStep(
            AgentState(messages: [.system("You are Avyra."), .user("where do I live?")])
        )

        XCTAssertTrue(state.messages.contains { $0.textContent == "You are Avyra." })
    }
}

// MARK: - RecallRelevanceTests

/// `recall` returns the top *k* by similarity, which is not the same as
/// relevant. With a small store it returns the same handful every time
/// regardless of the question — in the field, "user lives in Berlin"
/// was injected into a fasting-status query on every single turn.
final class RecallRelevanceTests: XCTestCase {
    /// A floor keeps weak matches out entirely rather than letting them
    /// ride along at the bottom of the top-k.
    func testBelowFloorMatchesAreNotInjected() async throws {
        let middleware = RAGMiddleware(
            memoryStore: try await Self.store(),
            namespace: ["t"],
            topK: 5,
            // Above anything a hash embedder produces for unrelated
            // text, which is the point: nothing should clear it.
            minimumScore: 0.99,
            instructionPrefix: "## Recalled memories"
        )

        let state = try await middleware.beforeStep(
            AgentState(messages: [.user("what is my fasting status?")])
        )

        XCTAssertFalse(
            state.messages.contains { $0.textContent.hasPrefix("## Recalled memories") },
            "Nothing cleared the floor, so nothing should be injected"
        )
    }

    /// Off by default: the right floor is a property of the embedder,
    /// and inheriting a guess would silently empty memory.
    func testNoFloorInjectsAsBefore() async throws {
        let middleware = RAGMiddleware(
            memoryStore: try await Self.store(),
            namespace: ["t"],
            topK: 5,
            instructionPrefix: "## Recalled memories"
        )

        let state = try await middleware.beforeStep(
            AgentState(messages: [.user("what is my fasting status?")])
        )

        XCTAssertTrue(
            state.messages.contains { $0.textContent.hasPrefix("## Recalled memories") }
        )
    }

    private static func store() async throws -> DefaultMemoryStore {
        let embedder = HashEmbedder(dimensions: 64)
        let store = DefaultMemoryStore(
            embedder: embedder,
            store: InMemoryVectorStore(dimensions: embedder.dimensions)
        )
        try await store.remember(MemoryItem(content: "user lives in Berlin"), namespace: ["t"])
        return store
    }
}
