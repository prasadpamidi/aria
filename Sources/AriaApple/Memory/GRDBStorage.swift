#if canImport(Foundation) && (os(iOS) || os(macOS) || os(watchOS) || os(tvOS) || os(visionOS))

    import Aria
    import Foundation
    import GRDB

    // MARK: - GRDBStorage

    /// A shared SQLite container that hosts Aria's `ChatHistory`,
    /// `Checkpointer`, and `VectorStore` implementations.
    ///
    /// One `GRDBStorage` corresponds to one SQLite file. The accessors
    /// return implementations bound to this container; all share the
    /// same `DatabaseQueue` so reads and writes serialize cleanly.
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

        /// Exposed so vector stores (and their migrations) can share the
        /// same connection and schema the app migrates.
        public let dbQueue: DatabaseQueue

        /// A `ChatHistory` writing to this storage.
        public var chatHistory: GRDBChatHistory {
            GRDBChatHistory(dbQueue: self.dbQueue)
        }

        /// A `Checkpointer` writing to this storage.
        public var checkpointer: GRDBCheckpointer {
            GRDBCheckpointer(dbQueue: self.dbQueue)
        }

        /// A `VectorStore` writing to this storage. Pass the
        /// dimensionality of the embedder you intend to use; one storage
        /// can host vectors at multiple dimensionalities — items with
        /// the wrong dimension count are filtered out on read.
        /// - Parameter embedderIdentifier: Which embedder's vectors
        ///   this store should read. Passing it is what makes a model
        ///   change visible instead of silently emptying memory.
        public func vectorStore(
            dimensions: Int,
            embedderIdentifier: String = ""
        ) -> GRDBVectorStore {
            GRDBVectorStore(
                dbQueue: self.dbQueue,
                dimensions: dimensions,
                embedderIdentifier: embedderIdentifier
            )
        }

        // MARK: Private

        private static let migrator: DatabaseMigrator = {
            var migrator = DatabaseMigrator()
            migrator.registerMigration("v1.tables", migrate: Self.migrateV1Tables(_:))
            migrator.registerMigration("v2.vectors", migrate: Self.migrateV2Vectors(_:))
            migrator.registerMigration("v3.embedderIdentity", migrate: Self.migrateV3EmbedderIdentity(_:))
            return migrator
        }()

        private static func migrateV1Tables(_ db: Database) throws {
            try self.createMessagesTable(db)
            try self.createCheckpointsTable(db)
        }

        private static func migrateV2Vectors(_ db: Database) throws {
            try self.createVectorItemsTable(db)
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

        /// Record which embedder produced each vector.
        ///
        /// Search matched on `dimensions` alone, which is not identity:
        /// two different 384-wide models compare cleanly and return
        /// confident nonsense, and swapping to a 512-wide one returns
        /// nothing at all — silently, with no error, indistinguishable
        /// from an empty store. Existing rows get an empty identifier,
        /// which no live embedder will claim, so they are re-embedded
        /// rather than trusted.
        private static func migrateV3EmbedderIdentity(_ db: Database) throws {
            try db.alter(table: "vector_items") { table in
                table.add(column: "embedderId", .text).notNull().defaults(to: "")
            }
            try db.create(
                indexOn: "vector_items",
                columns: ["embedderId", "dimensions"]
            )
        }

        private static func createVectorItemsTable(_ db: Database) throws {
            try db.create(table: "vector_items") { table in
                table.column("id", .text).primaryKey()
                table.column("dimensions", .integer).notNull()
                table.column("vector", .blob).notNull()
                table.column("content", .text).notNull()
                table.column("metadataJSON", .text).notNull()
            }
            try db.create(
                indexOn: "vector_items",
                columns: ["dimensions"]
            )
        }
    }

#endif
