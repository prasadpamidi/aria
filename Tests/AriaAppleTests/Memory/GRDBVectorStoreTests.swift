#if canImport(Foundation) && (os(iOS) || os(macOS) || os(watchOS) || os(tvOS) || os(visionOS))

    import Foundation
    import XCTest
    @testable import Aria
    @testable import AriaApple
    @testable import AriaTesting

    final class GRDBVectorStoreTests: XCTestCase {
        func testUpsertAndSearchByCosineRanking() async throws {
            let storage = try GRDBStorage()
            let store = storage.vectorStore(dimensions: 3)

            try await store.upsert([
                VectorItem(id: "a", vector: [1, 0, 0], content: "alpha"),
                VectorItem(id: "b", vector: [0, 1, 0], content: "beta"),
                VectorItem(id: "c", vector: [0.9, 0.1, 0], content: "almost-alpha"),
            ])

            let matches = try await store.search(query: [1, 0, 0], topK: 2, filter: nil)
            XCTAssertEqual(matches.map(\.id), ["a", "c"])
            XCTAssertEqual(matches.first?.score ?? 0, 1, accuracy: 0.0001)
        }

        func testDimensionMismatchOnUpsertThrows() async throws {
            let storage = try GRDBStorage()
            let store = storage.vectorStore(dimensions: 3)
            do {
                try await store.upsert([
                    VectorItem(id: "a", vector: [1, 0], content: "wrong-shape"),
                ])
                XCTFail("Expected configurationInvalid")
            } catch let error as AgentError {
                if case .configurationInvalid = error {
                    // expected
                } else {
                    XCTFail("Got \(error)")
                }
            }
        }

        func testFilePersistsAcrossInstances() async throws {
            let url = FileManager.default
                .temporaryDirectory
                .appendingPathComponent("aria-vec-test-\(UUID().uuidString).sqlite")
            defer { try? FileManager.default.removeItem(at: url) }

            do {
                let storage = try GRDBStorage(url: url)
                let store = storage.vectorStore(dimensions: 4)
                try await store.upsert([
                    VectorItem(
                        id: "persisted",
                        vector: [0.1, 0.2, 0.3, 0.4],
                        content: "I survive a relaunch"
                    ),
                ])
            }

            let storage = try GRDBStorage(url: url)
            let store = storage.vectorStore(dimensions: 4)
            let matches = try await store.search(query: [0.1, 0.2, 0.3, 0.4], topK: 1, filter: nil)
            XCTAssertEqual(matches.first?.id, "persisted")
            XCTAssertEqual(matches.first?.content, "I survive a relaunch")
        }

        func testStoresAtDifferentDimensionsAreIsolated() async throws {
            let storage = try GRDBStorage()
            let store3 = storage.vectorStore(dimensions: 3)
            let store4 = storage.vectorStore(dimensions: 4)

            try await store3.upsert([
                VectorItem(id: "x3", vector: [1, 0, 0], content: "three-dim"),
            ])
            try await store4.upsert([
                VectorItem(id: "x4", vector: [1, 0, 0, 0], content: "four-dim"),
            ])

            let matches3 = try await store3.search(query: [1, 0, 0], topK: 5, filter: nil)
            let matches4 = try await store4.search(query: [1, 0, 0, 0], topK: 5, filter: nil)

            XCTAssertEqual(matches3.map(\.id), ["x3"])
            XCTAssertEqual(matches4.map(\.id), ["x4"])
        }

        func testFilterNarrowsResults() async throws {
            let storage = try GRDBStorage()
            let store = storage.vectorStore(dimensions: 2)

            try await store.upsert([
                VectorItem(
                    id: "a",
                    vector: [1, 0],
                    content: "alpha",
                    metadata: ["lang": .string("en")]
                ),
                VectorItem(
                    id: "b",
                    vector: [1, 0],
                    content: "alfa",
                    metadata: ["lang": .string("es")]
                ),
            ])

            let matches = try await store.search(
                query: [1, 0],
                topK: 5,
                filter: .equals(field: "lang", value: .string("es"))
            )
            XCTAssertEqual(matches.map(\.id), ["b"])
        }

        func testDeleteRemovesByIdAndOthersByOtherIdsRemain() async throws {
            let storage = try GRDBStorage()
            let store = storage.vectorStore(dimensions: 1)

            try await store.upsert([
                VectorItem(id: "a", vector: [1], content: "x"),
                VectorItem(id: "b", vector: [1], content: "y"),
                VectorItem(id: "c", vector: [1], content: "z"),
            ])

            try await store.delete(ids: ["a", "c"])

            let count = try await store.count(filter: nil)
            XCTAssertEqual(count, 1)
            let matches = try await store.search(query: [1], topK: 5, filter: nil)
            XCTAssertEqual(matches.map(\.id), ["b"])
        }

        func testListReturnsAllOrFiltered() async throws {
            let storage = try GRDBStorage()
            let store = storage.vectorStore(dimensions: 1)

            try await store.upsert([
                VectorItem(
                    id: "a",
                    vector: [1],
                    content: "alpha",
                    metadata: ["k": .string("x")]
                ),
                VectorItem(
                    id: "b",
                    vector: [1],
                    content: "beta",
                    metadata: ["k": .string("y")]
                ),
            ])

            let all = try await store.list(filter: nil, limit: 10)
            XCTAssertEqual(Set(all.map(\.id)), Set(["a", "b"]))

            let filtered = try await store.list(
                filter: .equals(field: "k", value: .string("x")),
                limit: 10
            )
            XCTAssertEqual(filtered.map(\.id), ["a"])
        }

        func testReplacesOnUpsertWithSameId() async throws {
            let storage = try GRDBStorage()
            let store = storage.vectorStore(dimensions: 2)

            try await store.upsert([
                VectorItem(id: "a", vector: [1, 0], content: "first"),
            ])
            try await store.upsert([
                VectorItem(id: "a", vector: [0, 1], content: "second"),
            ])

            let count = try await store.count(filter: nil)
            XCTAssertEqual(count, 1)
            let matches = try await store.search(query: [0, 1], topK: 1, filter: nil)
            XCTAssertEqual(matches.first?.content, "second")
        }
    }

    final class GRDBStorageVectorIntegrationTests: XCTestCase {
        /// `DefaultMemoryStore` paired with `GRDBVectorStore` should
        /// behave identically to the in-memory variant — namespace
        /// isolation, recall, list — but the memories survive process
        /// restarts.
        func testDefaultMemoryStoreOverGRDBPersistsAcrossInstances() async throws {
            let url = FileManager.default
                .temporaryDirectory
                .appendingPathComponent("aria-mem-test-\(UUID().uuidString).sqlite")
            defer { try? FileManager.default.removeItem(at: url) }

            do {
                let storage = try GRDBStorage(url: url)
                let memory = DefaultMemoryStore(
                    embedder: HashEmbedder(dimensions: 32),
                    store: storage.vectorStore(dimensions: 32)
                )
                _ = try await memory.remember(
                    MemoryItem(content: "user prefers metric units"),
                    namespace: ["user_42"]
                )
            }

            let storage = try GRDBStorage(url: url)
            let memory = DefaultMemoryStore(
                embedder: HashEmbedder(dimensions: 32),
                store: storage.vectorStore(dimensions: 32)
            )
            let matches = try await memory.recall(
                query: "what units does the user prefer?",
                namespace: ["user_42"],
                topK: 3,
                filter: nil
            )
            XCTAssertEqual(matches.first?.item.content, "user prefers metric units")
        }
    }

#endif
