import Foundation
import XCTest
@testable import Aria
@testable import AriaTesting

// MARK: - DefaultMemoryStoreTests

final class DefaultMemoryStoreTests: XCTestCase {
    func makeStore() -> DefaultMemoryStore {
        let embedder = HashEmbedder(dimensions: 64)
        let vectorStore = InMemoryVectorStore(dimensions: embedder.dimensions)
        return DefaultMemoryStore(embedder: embedder, store: vectorStore)
    }

    func testRememberAndRecallReturnsTheSameContent() async throws {
        let store = self.makeStore()
        let ref = try await store.remember(
            MemoryItem(content: "user prefers metric units"),
            namespace: ["user_42", "preferences"]
        )

        let matches = try await store.recall(
            query: "what units does the user prefer?",
            namespace: ["user_42", "preferences"],
            topK: 5,
            filter: nil
        )

        XCTAssertEqual(ref.namespace, ["user_42", "preferences"])
        XCTAssertEqual(matches.first?.item.id, ref.id)
        XCTAssertEqual(matches.first?.item.content, "user prefers metric units")
    }

    func testRecallIsNamespaceIsolated() async throws {
        let store = self.makeStore()
        try await store.remember(
            MemoryItem(content: "user_42 likes coffee"),
            namespace: ["user_42"]
        )
        try await store.remember(
            MemoryItem(content: "user_99 likes tea"),
            namespace: ["user_99"]
        )

        let matches42 = try await store.recall(
            query: "drinks",
            namespace: ["user_42"],
            topK: 5,
            filter: nil
        )
        let matches99 = try await store.recall(
            query: "drinks",
            namespace: ["user_99"],
            topK: 5,
            filter: nil
        )

        XCTAssertEqual(matches42.map(\.item.content), ["user_42 likes coffee"])
        XCTAssertEqual(matches99.map(\.item.content), ["user_99 likes tea"])
    }

    func testForgetRemovesEntry() async throws {
        let store = self.makeStore()
        let ref = try await store.remember(
            MemoryItem(id: "fact-1", content: "something to forget"),
            namespace: ["t"]
        )
        try await store.forget(id: ref.id, namespace: ["t"])

        let matches = try await store.recall(
            query: "something",
            namespace: ["t"],
            topK: 5,
            filter: nil
        )
        XCTAssertTrue(matches.isEmpty)
    }

    func testListInNamespacePreservesUserMetadataAndCreatedAt() async throws {
        let store = self.makeStore()
        let timestamp = Date(timeIntervalSince1970: 1_234_567_890)
        try await store.remember(
            MemoryItem(
                id: "fact-x",
                content: "important fact",
                metadata: ["confidence": .number(0.9)],
                createdAt: timestamp
            ),
            namespace: ["t"]
        )

        let listed = try await store.list(namespace: ["t"], limit: 10)
        XCTAssertEqual(listed.count, 1)
        let first = try XCTUnwrap(listed.first)
        XCTAssertEqual(first.id, "fact-x")
        XCTAssertEqual(first.metadata["confidence"], .number(0.9))
        XCTAssertEqual(
            first.createdAt.timeIntervalSince1970,
            timestamp.timeIntervalSince1970,
            accuracy: 0.001
        )
        // The internal namespace + createdAt keys should be stripped from
        // the public-facing metadata.
        XCTAssertNil(first.metadata[DefaultMemoryStore.namespaceKey])
        XCTAssertNil(first.metadata[DefaultMemoryStore.createdAtKey])
    }
}

// MARK: - HashEmbedderTests

final class HashEmbedderTests: XCTestCase {
    func testProducesNormalizedDeterministicVectors() async throws {
        let embedder = HashEmbedder(dimensions: 16)
        let first = try await embedder.embed(["hello"])
        let again = try await embedder.embed(["hello"])
        XCTAssertEqual(first, again)

        let magnitude = first[0].reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        XCTAssertEqual(magnitude, 1, accuracy: 0.001)
    }

    func testBatchEmbeddingMatchesSingleEmbedding() async throws {
        let embedder = HashEmbedder(dimensions: 8)
        let single = try await embedder.embed("foo")
        let batched = try await embedder.embed(["foo"])
        XCTAssertEqual(single, batched[0])
    }
}
