#if canImport(GRDB)
    import Foundation
    import GRDB

    // MARK: - WorkflowMigrator

    /// Schema migrations for the WorkflowKit-owned SQLite database.
    ///
    /// Append-only: never edit a previously-shipped migration body.
    /// Schema changes that need to mutate existing rows go in a new
    /// migration that touches the affected columns; `bodyJSON` blob
    /// changes are usually handled via `WorkflowCodec` decode
    /// compatibility instead.
    enum WorkflowMigrator {
        // MARK: Internal

        /// Build the canonical migrator. Idempotent; safe to call
        /// repeatedly on the same database.
        static func makeMigrator() -> DatabaseMigrator {
            var migrator = DatabaseMigrator()
            migrator.registerMigration("v1.workflows", migrate: Self.migrateV1(_:))
            return migrator
        }

        // MARK: Private

        private static func migrateV1(_ database: Database) throws {
            try database.create(table: WorkflowRecord.databaseTableName) { table in
                table.column("id", .text).primaryKey()
                table.column("name", .text).notNull()
                // `.double` matches GRDBStorage's Date columns and
                // makes the `ORDER BY updatedAt DESC` list query a
                // direct sort on a native column.
                table.column("updatedAt", .double).notNull()
                // Workflow blob — JSON-as-text rather than blob so a
                // sqlite3-CLI inspection of the row reads as
                // human-friendly content.
                table.column("bodyJSON", .blob).notNull()
            }
            try database.create(
                indexOn: WorkflowRecord.databaseTableName,
                columns: ["updatedAt"]
            )
        }
    }
#endif
