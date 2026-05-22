#if canImport(GRDB)
    import Foundation
    import GRDB

    // MARK: - WorkflowStore

    /// Workflow persistence layer. Owns its own SQLite database
    /// (separate from AriaApple's `GRDBStorage`) so the workflow
    /// catalogue doesn't entangle with chat-history schema. Both
    /// live in the same `Application Support/avyra/` directory in
    /// the app; they just don't share a file.
    ///
    /// `Sendable` because GRDB's `DatabaseQueue` is documented as
    /// thread-safe — its serialization model is a single-writer
    /// queue under the hood, which is exactly what the workflow
    /// editor + AppIntent dispatcher need. Callers can read and
    /// write from any task without external locking.
    public struct WorkflowStore: Sendable {
        // MARK: Lifecycle

        /// Open or create the SQLite database at `url`. Runs
        /// pending migrations before returning. Throws on
        /// unrecoverable migration errors (corrupted schema).
        public init(url: URL) throws {
            self.dbQueue = try DatabaseQueue(path: url.path)
            try WorkflowMigrator.makeMigrator().migrate(self.dbQueue)
        }

        /// In-memory database. Used in unit tests and previews so
        /// each test gets a fresh, isolated catalogue.
        public init() throws {
            self.dbQueue = try DatabaseQueue()
            try WorkflowMigrator.makeMigrator().migrate(self.dbQueue)
        }

        // MARK: Public

        /// Lightweight summary returned by `list()`. Holding the
        /// full JSON blob in memory for every row was overkill —
        /// callers that need the body call `load(id:)` for the
        /// row they're about to edit.
        public struct Summary: Sendable, Equatable {
            public let id: UUID
            public let name: String
            public let updatedAt: Date
        }

        /// Insert or update a workflow. Bumps `updatedAt` to the
        /// passed workflow's value (the caller is expected to set
        /// it; the store doesn't second-guess timestamps so tests
        /// can assert deterministic values).
        public func save(_ workflow: Workflow) throws {
            try self.dbQueue.write { database in
                var record = try WorkflowRecord(workflow: workflow)
                try record.save(database)
            }
        }

        /// Load one workflow by id. Returns `nil` when the id
        /// isn't present rather than throwing — the caller's
        /// "deleted while another surface had a stale id" path
        /// is a common, non-exceptional outcome.
        public func load(id: UUID) throws -> Workflow? {
            try self.dbQueue.read { database in
                guard let record = try WorkflowRecord.fetchOne(
                    database,
                    key: id.uuidString
                ) else {
                    return nil
                }
                return try record.toWorkflow()
            }
        }

        /// List all workflows ordered by most-recently-updated
        /// first. Returns lightweight summaries (only the fields
        /// needed for a library-row render) so callers don't
        /// decode every blob just to populate a list view.
        public func list() throws -> [Summary] {
            try self.dbQueue.read { database in
                let rows = try WorkflowRecord
                    .order(WorkflowRecord.Columns.updatedAt.desc)
                    .fetchAll(database)
                return try rows.map { row in
                    guard let identifier = UUID(uuidString: row.id) else {
                        throw WorkflowStoreError.invalidStoredID(row.id)
                    }
                    return Summary(
                        id: identifier,
                        name: row.name,
                        updatedAt: row.updatedAt
                    )
                }
            }
        }

        /// Delete a workflow by id. No-op when the id isn't
        /// present — same idempotent shape as `load`.
        public func delete(id: UUID) throws {
            _ = try self.dbQueue.write { database in
                try WorkflowRecord.deleteOne(database, key: id.uuidString)
            }
        }

        /// Convenience for tests + dev-mode "clear all workflows".
        public func deleteAll() throws {
            _ = try self.dbQueue.write { database in
                try WorkflowRecord.deleteAll(database)
            }
        }

        // MARK: Private

        private let dbQueue: DatabaseQueue
    }

    // MARK: - WorkflowStoreError

    public enum WorkflowStoreError: Error, Sendable, Equatable {
        /// A stored row's `id` column couldn't be parsed back into a
        /// UUID. Shouldn't be reachable in practice — every write
        /// goes through `WorkflowRecord(workflow:)` which formats
        /// from a typed UUID — but surfaced rather than crashed so
        /// a corrupted database fails loud.
        case invalidStoredID(String)
    }
#endif
