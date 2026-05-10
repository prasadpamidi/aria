#if canImport(Foundation) && (os(iOS) || os(macOS) || os(watchOS) || os(tvOS) || os(visionOS))

    import Aria
    import Foundation
    import GRDB

    // MARK: - GRDBCheckpointer

    /// A `Checkpointer` backed by GRDB / SQLite.
    ///
    /// Shares its `DatabaseQueue` with `GRDBChatHistory` when both come
    /// from the same `GRDBStorage`, so checkpointing and message
    /// persistence happen against one consistent file.
    public struct GRDBCheckpointer: Checkpointer {
        // MARK: Lifecycle

        public init(dbQueue: DatabaseQueue) {
            self.dbQueue = dbQueue
        }

        // MARK: Public

        public func put(
            _ checkpoint: Checkpoint,
            threadId _: String
        ) async throws {
            try await self.dbQueue.write { db in
                try Self.insertOrReplace(checkpoint: checkpoint, into: db)
            }
        }

        public func get(
            threadId: String,
            checkpointId: String?
        ) async throws -> Checkpoint? {
            try await self.dbQueue.read { db in
                if let checkpointId {
                    return try Self.byId(checkpointId, from: db)
                }
                return try Self.latest(threadId: threadId, from: db)
            }
        }

        public func list(
            threadId: String,
            limit: Int
        ) async throws -> [Checkpoint] {
            try await self.dbQueue.read { db in
                let rows = try CheckpointRow.fetchAll(
                    db,
                    sql: """
                    SELECT * FROM checkpoints
                    WHERE threadId = ?
                    ORDER BY createdAt DESC
                    LIMIT ?
                    """,
                    arguments: [threadId, limit]
                )
                return try rows.map { try $0.decode() }
            }
        }

        public func deleteThread(_ threadId: String) async throws {
            try await self.dbQueue.write { db in
                try db.execute(
                    sql: "DELETE FROM checkpoints WHERE threadId = ?",
                    arguments: [threadId]
                )
            }
        }

        // MARK: Private

        private let dbQueue: DatabaseQueue

        private static func insertOrReplace(
            checkpoint: Checkpoint,
            into db: Database
        ) throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let metadataJSON = try String(
                bytes: encoder.encode(checkpoint.metadata),
                encoding: .utf8
            ) ?? "{}"
            try db.execute(
                sql: """
                INSERT OR REPLACE INTO checkpoints
                (id, threadId, parentId, createdAt, state, metadataJSON)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    checkpoint.id,
                    checkpoint.threadId,
                    checkpoint.parentId,
                    checkpoint.createdAt.timeIntervalSinceReferenceDate,
                    checkpoint.state,
                    metadataJSON
                ]
            )
        }

        private static func byId(_ id: String, from db: Database) throws -> Checkpoint? {
            try CheckpointRow
                .fetchOne(
                    db,
                    sql: "SELECT * FROM checkpoints WHERE id = ?",
                    arguments: [id]
                )?
                .decode()
        }

        private static func latest(
            threadId: String,
            from db: Database
        ) throws -> Checkpoint? {
            try CheckpointRow
                .fetchOne(
                    db,
                    sql: """
                    SELECT * FROM checkpoints
                    WHERE threadId = ?
                    ORDER BY createdAt DESC LIMIT 1
                    """,
                    arguments: [threadId]
                )?
                .decode()
        }
    }

    // MARK: - CheckpointRow

    private struct CheckpointRow: Codable, FetchableRecord {
        let id: String
        let threadId: String
        let parentId: String?
        let createdAt: Double
        let state: Data
        let metadataJSON: String

        func decode() throws -> Checkpoint {
            let metadata = try JSONDecoder().decode(
                [String: JSONValue].self,
                from: Data(self.metadataJSON.utf8)
            )
            return Checkpoint(
                id: self.id,
                threadId: self.threadId,
                parentId: self.parentId,
                createdAt: Date(timeIntervalSinceReferenceDate: self.createdAt),
                state: self.state,
                metadata: metadata
            )
        }
    }

#endif
