#if canImport(GRDB)
    import Foundation
    import GRDB

    // MARK: - WorkflowRecord

    /// GRDB row shape for the `workflows` table. The full `Workflow`
    /// is serialised to JSON (`bodyJSON`) so adding new fields to
    /// `Workflow` never requires a SQLite schema change — only the
    /// `Codable` round-trip needs to stay backwards-compatible.
    ///
    /// A small set of fields is mirrored into native columns
    /// (`name`, `updatedAt`) so list views can render + sort without
    /// having to decode every row's JSON blob. Those columns are
    /// derived state — they're recomputed from `bodyJSON` on each
    /// save.
    struct WorkflowRecord: Codable, FetchableRecord, MutablePersistableRecord {
        enum Columns: String, ColumnExpression {
            case id, name, updatedAt, bodyJSON
        }

        static let databaseTableName = "workflows"

        let id: String
        let name: String
        let updatedAt: Date
        let bodyJSON: Data
    }

    extension WorkflowRecord {
        /// Lift a `Workflow` into its row form. Encoding uses the
        /// canonical compact JSON (no pretty-printing — diff
        /// stability is a property of `.workflow.json` exports, not
        /// the on-disk blob).
        init(workflow: Workflow) throws {
            self.id = workflow.id.uuidString
            self.name = workflow.name
            self.updatedAt = workflow.updatedAt
            self.bodyJSON = try WorkflowCodec.encode(workflow)
        }

        /// Decode the row back into a `Workflow`. Surfaces JSON
        /// decode errors directly so a corrupted row doesn't get
        /// silently turned into a default-shaped workflow.
        func toWorkflow() throws -> Workflow {
            try WorkflowCodec.decode(self.bodyJSON)
        }
    }
#endif
