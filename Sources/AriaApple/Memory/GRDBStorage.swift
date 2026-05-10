#if canImport(Foundation) && (os(iOS) || os(macOS) || os(watchOS) || os(tvOS) || os(visionOS))

    import Aria
    import Foundation
    import GRDB

    // MARK: - GRDBStorage

    /// A shared SQLite container that hosts Aria's `ChatHistory` and
    /// `Checkpointer` implementations.
    ///
    /// One `GRDBStorage` corresponds to one SQLite file. The
    /// `chatHistory` and `checkpointer` accessors return implementations
    /// bound to this container; both share the same `DatabaseQueue` so
    /// reads and writes serialize cleanly.
    ///
    /// Migrations are registered up front and run lazily on first use.
    /// New schema versions are append-only — never edit a previously
    /// shipped migration body.
    public struct GRDBStorage: Sendable {
        // MARK: Lifecycle

        /// Open or create the SQLite database at `url`. Throws if the
        /// file is unreadable or the migrations cannot be applied.
        public init(url: URL) throws {
            self.dbQueue = try DatabaseQueue(path: url.path)
            try Self.migrator.migrate(self.dbQueue)
        }

        /// In-memory database. Useful for tests and previews.
        public init() throws {
            self.dbQueue = try DatabaseQueue()
            try Self.migrator.migrate(self.dbQueue)
        }

        // MARK: Public

        /// A `ChatHistory` writing to this storage.
        public var chatHistory: GRDBChatHistory {
            GRDBChatHistory(dbQueue: self.dbQueue)
        }

        /// A `Checkpointer` writing to this storage.
        public var checkpointer: GRDBCheckpointer {
            GRDBCheckpointer(dbQueue: self.dbQueue)
        }

        // MARK: Internal

        let dbQueue: DatabaseQueue

        // MARK: Private

        private static let migrator: DatabaseMigrator = {
            var migrator = DatabaseMigrator()
            migrator.registerMigration("v1.tables", migrate: Self.migrateV1Tables(_:))
            return migrator
        }()

        private static func migrateV1Tables(_ db: Database) throws {
            try self.createMessagesTable(db)
            try self.createCheckpointsTable(db)
        }

        private static func createMessagesTable(_ db: Database) throws {
            try db.create(table: "messages") { table in
                table.autoIncrementedPrimaryKey("rowId")
                table.column("threadId", .text).notNull().indexed()
                table.column("role", .text).notNull()
                table.column("contentJSON", .text).notNull()
                table.column("toolCallsJSON", .text).notNull()
                table.column("toolCallId", .text)
                table.column("metadataJSON", .text).notNull()
                table.column("createdAt", .double).notNull()
            }
            try db.create(
                indexOn: "messages",
                columns: ["threadId", "createdAt"]
            )
        }

        private static func createCheckpointsTable(_ db: Database) throws {
            try db.create(table: "checkpoints") { table in
                table.column("id", .text).primaryKey()
                table.column("threadId", .text).notNull().indexed()
                table.column("parentId", .text)
                table.column("createdAt", .double).notNull()
                table.column("state", .blob).notNull()
                table.column("metadataJSON", .text).notNull()
            }
            try db.create(
                indexOn: "checkpoints",
                columns: ["threadId", "createdAt"]
            )
        }
    }

#endif
