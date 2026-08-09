#if canImport(GRDB)
    import Aria
    @testable import AriaApple
    import AriaTesting
    import GRDB
    import XCTest

    // MARK: - VectorStoreMigrationTests

    /// Dimension is not identity.
    ///
    /// Search matched on `dimensions` alone. Two different 384-wide
    /// models compare cleanly and rank confident nonsense; a 512-wide
    /// one returns nothing at all — silently, with no error, and
    /// indistinguishable from an empty store. That is what made
    /// swapping the memory embedder unsafe.
    final class VectorStoreMigrationTests: XCTestCase {
        /// The failure this prevents: a model change quietly emptying
        /// memory while every row is still on disk.
        func testAnotherEmbeddersRowsAreNotReturned() async throws {
            let queue = try Self.queue()
            let old = GRDBVectorStore(dbQueue: queue, dimensions: 8, embedderIdentifier: "old")
            try await old.upsert([Self.item(id: "a", value: 1)])

            let new = GRDBVectorStore(dbQueue: queue, dimensions: 8, embedderIdentifier: "new")
            let results = try await new.search(query: Self.vector(1), topK: 5, filter: nil)

            XCTAssertTrue(results.isEmpty, "Vectors from another model must not be compared")
        }

        /// And the recovery: content is the source of truth, so the
        /// vectors can be rebuilt.
        func testReembeddingRecoversTheRows() async throws {
            let queue = try Self.queue()
            let old = GRDBVectorStore(dbQueue: queue, dimensions: 8, embedderIdentifier: "old")
            try await old.upsert([Self.item(id: "a", value: 1)])

            let embedder = HashEmbedder(dimensions: 8)
            let new = GRDBVectorStore(
                dbQueue: queue,
                dimensions: 8,
                embedderIdentifier: embedder.modelIdentifier
            )
            let migrated = try await new.reembed(with: embedder)
            XCTAssertEqual(migrated, 1)

            let query = try await embedder.embed("remembered text")
            let results = try await new.search(query: query, topK: 5, filter: nil)
            XCTAssertEqual(results.first?.id, "a")
        }

        /// Idempotent — a launch-time call must not re-embed the world
        /// every time.
        func testReembeddingIsIdempotent() async throws {
            let queue = try Self.queue()
            let embedder = HashEmbedder(dimensions: 8)
            let store = GRDBVectorStore(
                dbQueue: queue,
                dimensions: 8,
                embedderIdentifier: embedder.modelIdentifier
            )
            try await store.upsert([Self.item(id: "a", value: 1)])

            let migrated = try await store.reembed(with: embedder)
            XCTAssertEqual(migrated, 0)
        }

        /// Content and metadata survive the rebuild — only the vector
        /// is derived.
        func testReembeddingPreservesContentAndMetadata() async throws {
            let queue = try Self.queue()
            let old = GRDBVectorStore(dbQueue: queue, dimensions: 8, embedderIdentifier: "old")
            try await old.upsert([
                VectorItem(
                    id: "a",
                    vector: Self.vector(1),
                    content: "user is vegetarian",
                    metadata: ["source": .string("toolCall")]
                ),
            ])

            let embedder = HashEmbedder(dimensions: 8)
            let new = GRDBVectorStore(
                dbQueue: queue,
                dimensions: 8,
                embedderIdentifier: embedder.modelIdentifier
            )
            try await new.reembed(with: embedder)

            let items = try await new.list(filter: nil, limit: 10)
            XCTAssertEqual(items.first?.content, "user is vegetarian")
            XCTAssertEqual(items.first?.metadata["source"], .string("toolCall"))
        }

        // MARK: Fixtures

        /// Reuses `GRDBStorage` so the schema under test is the one
        /// the app actually migrates to, not a hand-built copy.
        private static func queue() throws -> DatabaseQueue {
            try GRDBStorage().dbQueue
        }

        private static func vector(_ value: Float) -> [Float] {
            Array(repeating: value, count: 8)
        }

        private static func item(id: String, value: Float) -> VectorItem {
            VectorItem(id: id, vector: Self.vector(value), content: "remembered text", metadata: [:])
        }
    }
#endif
