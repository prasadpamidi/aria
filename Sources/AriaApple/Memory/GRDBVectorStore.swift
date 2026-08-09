#if canImport(Foundation) && (os(iOS) || os(macOS) || os(watchOS) || os(tvOS) || os(visionOS))

    import Aria
    import Foundation
    import GRDB

    // MARK: - GRDBVectorStore

    /// A persistent `VectorStore` backed by GRDB / SQLite.
    ///
    /// Vectors are stored as little-endian raw `Float` bytes in a BLOB
    /// column. Search loads matching rows (by `dimensions`) and ranks
    /// them with cosine similarity in Swift — the same algorithm
    /// `InMemoryVectorStore` uses, just sourced from disk.
    ///
    /// This is the right tier for on-device agent memory at the scale
    /// most apps will see (hundreds to low thousands of items per
    /// embedder dimensionality). For workloads beyond ~10k items per
    /// dimensionality, swap in an ANN-indexed store (e.g., a future
    /// `sqlite-vec`-backed implementation) — both conform to the same
    /// protocol so the upgrade is transparent.
    ///
    /// Created via `GRDBStorage.vectorStore(dimensions:)`. The storage
    /// already migrates the `vector_items` table.
    public struct GRDBVectorStore: VectorStore {
        // MARK: Lifecycle

        /// - Parameter embedderIdentifier: Which embedder produced the
        ///   vectors this store should read.
        ///
        ///   Dimension is not identity. Two different 384-wide models
        ///   compare cleanly and rank confident nonsense; a 512-wide
        ///   one returns nothing at all, silently, which is
        ///   indistinguishable from an empty store. Passing the
        ///   identifier makes a model change *visible* — and
        ///   `reembed(with:)` makes it survivable.
        ///
        ///   Defaults to `""` so existing databases keep working: rows
        ///   written before this existed carry the same empty value.
        public init(
            dbQueue: DatabaseQueue,
            dimensions: Int,
            embedderIdentifier: String = ""
        ) {
            self.dbQueue = dbQueue
            self.dimensions = dimensions
            self.embedderIdentifier = embedderIdentifier
        }

        // MARK: Public

        public let dimensions: Int

        /// Identifier of the embedder whose vectors this store reads.
        public let embedderIdentifier: String

        public func upsert(_ items: [VectorItem]) async throws {
            for item in items {
                try self.validate(item.vector)
            }
            let identifier = self.embedderIdentifier
            try await self.dbQueue.write { db in
                for item in items {
                    try Self.insertOrReplace(item: item, embedderId: identifier, into: db)
                }
            }
        }

        public func search(
            query: [Float],
            topK: Int,
            filter: VectorFilter?
        ) async throws -> [VectorMatch] {
            try self.validate(query)
            let candidates = try await self.loadCandidates(filter: filter)
            let scored = candidates.map { item in
                (item, Self.cosineSimilarity(query, item.vector))
            }
            let top = scored
                .sorted { $0.1 > $1.1 }
                .prefix(max(0, topK))
            return top.map { item, score in
                VectorMatch(
                    id: item.id,
                    score: score,
                    content: item.content,
                    metadata: item.metadata
                )
            }
        }

        public func delete(ids: [String]) async throws {
            guard !ids.isEmpty else {
                return
            }
            try await self.dbQueue.write { db in
                let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
                try db.execute(
                    sql: "DELETE FROM vector_items WHERE id IN (\(placeholders))",
                    arguments: StatementArguments(ids)
                )
            }
        }

        public func count(filter: VectorFilter?) async throws -> Int {
            let candidates = try await self.loadCandidates(filter: filter)
            return candidates.count
        }

        public func list(filter: VectorFilter?, limit: Int) async throws -> [VectorItem] {
            let candidates = try await self.loadCandidates(filter: filter)
            if limit < candidates.count {
                return Array(candidates.prefix(limit))
            }
            return candidates
        }

        /// Re-embed every row that a different embedder wrote.
        ///
        /// The alternative is silent data loss. Search matches on
        /// embedder identity, so after a model change the old rows are
        /// still there and simply never returned — memory looks empty
        /// while remaining full, and nothing surfaces an error.
        ///
        /// Content is the source of truth; vectors are derived, so they
        /// can be rebuilt. Returns how many rows were migrated so a
        /// caller can report progress or log it.
        ///
        /// Idempotent: rows already carrying this store's identifier
        /// are skipped, so calling it on every launch costs one query.
        @discardableResult
        public func reembed(with embedder: any Embedder, batchSize: Int = 32) async throws -> Int {
            let identifier = self.embedderIdentifier
            let stale = try await dbQueue.read { db in
                try VectorItemRow.fetchAll(
                    db,
                    sql: "SELECT * FROM vector_items WHERE embedderId <> ?",
                    arguments: [identifier]
                )
            }
            guard !stale.isEmpty else {
                return 0
            }

            var migrated = 0
            for chunk in stride(from: 0, to: stale.count, by: max(1, batchSize)).map({ start in
                Array(stale[start..<min(start + max(1, batchSize), stale.count)])
            }) {
                let vectors = try await embedder.embed(chunk.map(\.content))
                guard vectors.count == chunk.count else {
                    throw AgentError.providerFailed(
                        "Embedder returned \(vectors.count) vectors for \(chunk.count) inputs",
                        underlying: nil
                    )
                }
                var items: [VectorItem] = []
                for (row, vector) in zip(chunk, vectors) {
                    var item = try row.decode()
                    item = VectorItem(
                        id: item.id,
                        vector: vector,
                        content: item.content,
                        metadata: item.metadata
                    )
                    items.append(item)
                }
                try await self.upsert(items)
                migrated += items.count
            }
            return migrated
        }

        // MARK: Internal

        /// Cosine similarity over equally-sized vectors. Same algorithm
        /// `InMemoryVectorStore` uses; inlined here to avoid widening
        /// the core's public surface for a four-line helper.
        static func cosineSimilarity(_ lhs: [Float], _ rhs: [Float]) -> Float {
            var dot: Float = 0
            var magLHS: Float = 0
            var magRHS: Float = 0
            for index in 0..<lhs.count {
                dot += lhs[index] * rhs[index]
                magLHS += lhs[index] * lhs[index]
                magRHS += rhs[index] * rhs[index]
            }
            let denom = (magLHS * magRHS).squareRoot()
            return denom > 0 ? dot / denom : 0
        }

        // MARK: Private

        private let dbQueue: DatabaseQueue

        private static func insertOrReplace(
            item: VectorItem,
            embedderId: String,
            into db: Database
        ) throws {
            let row = try VectorItemRow(item: item, embedderId: embedderId)
            try db.execute(
                sql: """
                INSERT OR REPLACE INTO vector_items
                (id, embedderId, dimensions, vector, content, metadataJSON)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    row.id,
                    row.embedderId,
                    row.dimensions,
                    row.vector,
                    row.content,
                    row.metadataJSON
                ]
            )
        }

        private func validate(_ vector: [Float]) throws {
            guard vector.count == self.dimensions else {
                throw AgentError.configurationInvalid(
                    "Vector has \(vector.count) dimensions but store expects \(self.dimensions)"
                )
            }
        }

        /// Load every row matching this store's dimensionality, applying
        /// the optional `VectorFilter` in Swift after decoding metadata.
        ///
        /// We filter in Swift rather than SQL because metadata is stored
        /// as a JSON blob; for the scale we target this is a non-issue.
        private func loadCandidates(filter: VectorFilter?) async throws -> [VectorItem] {
            let storeDimensions = self.dimensions
            let identifier = self.embedderIdentifier
            return try await self.dbQueue.read { db in
                let rows = try VectorItemRow.fetchAll(
                    db,
                    sql: "SELECT * FROM vector_items WHERE dimensions = ? AND embedderId = ?",
                    arguments: [storeDimensions, identifier]
                )
                let items = try rows.map { try $0.decode() }
                guard let filter else {
                    return items
                }
                return items.filter { filter.matches($0.metadata) }
            }
        }
    }

    // MARK: - VectorItemRow

    private struct VectorItemRow: Codable, FetchableRecord {
        // MARK: Lifecycle

        init(item: VectorItem, embedderId: String) throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            self.id = item.id
            self.embedderId = embedderId
            self.dimensions = item.vector.count
            self.vector = Self.bytes(from: item.vector)
            self.content = item.content
            self.metadataJSON = try String(
                bytes: encoder.encode(item.metadata),
                encoding: .utf8
            ) ?? "{}"
        }

        // MARK: Internal

        let id: String
        let embedderId: String
        let dimensions: Int
        let vector: Data
        let content: String
        let metadataJSON: String

        func decode() throws -> VectorItem {
            let decoder = JSONDecoder()
            let metadata = try decoder.decode(
                [String: JSONValue].self,
                from: Data(self.metadataJSON.utf8)
            )
            let vector = Self.floats(from: self.vector, count: self.dimensions)
            return VectorItem(
                id: self.id,
                vector: vector,
                content: self.content,
                metadata: metadata
            )
        }

        // MARK: Private

        // MARK: BLOB <-> [Float] codec

        private static func bytes(from vector: [Float]) -> Data {
            vector.withUnsafeBufferPointer { buffer in
                Data(buffer: buffer)
            }
        }

        private static func floats(from data: Data, count: Int) -> [Float] {
            data.withUnsafeBytes { raw -> [Float] in
                let buffer = raw.bindMemory(to: Float.self)
                return Array(buffer.prefix(count))
            }
        }
    }

#endif
