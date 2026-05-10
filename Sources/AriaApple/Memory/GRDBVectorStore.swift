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

        public init(dbQueue: DatabaseQueue, dimensions: Int) {
            self.dbQueue = dbQueue
            self.dimensions = dimensions
        }

        // MARK: Public

        public let dimensions: Int

        public func upsert(_ items: [VectorItem]) async throws {
            for item in items {
                try self.validate(item.vector)
            }
            try await self.dbQueue.write { db in
                for item in items {
                    try Self.insertOrReplace(item: item, into: db)
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

        private static func insertOrReplace(item: VectorItem, into db: Database) throws {
            let row = try VectorItemRow(item: item)
            try db.execute(
                sql: """
                INSERT OR REPLACE INTO vector_items
                (id, dimensions, vector, content, metadataJSON)
                VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [
                    row.id,
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
            return try await self.dbQueue.read { db in
                let rows = try VectorItemRow.fetchAll(
                    db,
                    sql: "SELECT * FROM vector_items WHERE dimensions = ?",
                    arguments: [storeDimensions]
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

        init(item: VectorItem) throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            self.id = item.id
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
