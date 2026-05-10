#if canImport(Foundation) && (os(iOS) || os(macOS) || os(watchOS) || os(tvOS) || os(visionOS))

    import Aria
    import Foundation
    import GRDB

    // MARK: - GRDBChatHistory

    /// A `ChatHistory` backed by GRDB / SQLite.
    ///
    /// All reads and writes go through the shared `DatabaseQueue` from
    /// the parent `GRDBStorage`, which serializes access. Messages are
    /// stored with their content + tool-call payload as JSON strings —
    /// exactly the shape the `Codable` conformance produces.
    public struct GRDBChatHistory: ChatHistory {
        // MARK: Lifecycle

        public init(dbQueue: DatabaseQueue) {
            self.dbQueue = dbQueue
        }

        // MARK: Public

        public func append(_ message: Message, threadId: String) async throws {
            try await self.dbQueue.write { db in
                try Self.insert(message: message, threadId: threadId, into: db)
            }
        }

        public func appendAll(_ messages: [Message], threadId: String) async throws {
            try await self.dbQueue.write { db in
                for message in messages {
                    try Self.insert(message: message, threadId: threadId, into: db)
                }
            }
        }

        public func messages(
            threadId: String,
            limit: Int?,
            before: Date?
        ) async throws -> [Message] {
            try await self.dbQueue.read { db in
                try Self.select(threadId: threadId, limit: limit, before: before, from: db)
            }
        }

        public func clear(threadId: String) async throws {
            try await self.dbQueue.write { db in
                try db.execute(
                    sql: "DELETE FROM messages WHERE threadId = ?",
                    arguments: [threadId]
                )
            }
        }

        public func threads() async throws -> [String] {
            try await self.dbQueue.read { db in
                try String.fetchAll(
                    db,
                    sql: "SELECT DISTINCT threadId FROM messages ORDER BY threadId"
                )
            }
        }

        // MARK: Private

        private let dbQueue: DatabaseQueue

        private static func insert(
            message: Message,
            threadId: String,
            into db: Database
        ) throws {
            let row = try MessageRow(message: message, threadId: threadId)
            try db.execute(
                sql: """
                INSERT INTO messages (
                    threadId, role, contentJSON, toolCallsJSON,
                    toolCallId, metadataJSON, createdAt
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    row.threadId,
                    row.role,
                    row.contentJSON,
                    row.toolCallsJSON,
                    row.toolCallId,
                    row.metadataJSON,
                    row.createdAt
                ]
            )
        }

        private static func select(
            threadId: String,
            limit: Int?,
            before: Date?,
            from db: Database
        ) throws -> [Message] {
            var sql = "SELECT * FROM messages WHERE threadId = ?"
            var arguments: [DatabaseValueConvertible] = [threadId]
            if let before {
                sql += " AND createdAt < ?"
                arguments.append(before.timeIntervalSinceReferenceDate)
            }
            sql += " ORDER BY createdAt ASC, rowId ASC"
            if let limit {
                // To return the *last* `limit` messages we use ORDER BY
                // descending and re-sort; this avoids loading the whole
                // thread when the conversation is long.
                sql = sql.replacingOccurrences(
                    of: "ORDER BY createdAt ASC, rowId ASC",
                    with: "ORDER BY createdAt DESC, rowId DESC LIMIT ?"
                )
                arguments.append(limit)
            }
            let rows = try MessageRow.fetchAll(
                db,
                sql: sql,
                arguments: StatementArguments(arguments)
            )
            let messages = try rows.map { try $0.decode() }
            return limit == nil ? messages : messages.reversed()
        }
    }

    // MARK: - MessageRow

    private struct MessageRow: Codable, FetchableRecord {
        // MARK: Lifecycle

        init(message: Message, threadId: String) throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            self.threadId = threadId
            self.role = message.role.rawValue
            self.contentJSON = try String(
                bytes: encoder.encode(message.content),
                encoding: .utf8
            ) ?? "[]"
            self.toolCallsJSON = try String(
                bytes: encoder.encode(message.toolCalls),
                encoding: .utf8
            ) ?? "[]"
            self.toolCallId = message.toolCallId
            self.metadataJSON = try String(
                bytes: encoder.encode(message.metadata),
                encoding: .utf8
            ) ?? "{}"
            self.createdAt = message.createdAt.timeIntervalSinceReferenceDate
        }

        // MARK: Internal

        let threadId: String
        let role: String
        let contentJSON: String
        let toolCallsJSON: String
        let toolCallId: String?
        let metadataJSON: String
        let createdAt: Double

        func decode() throws -> Message {
            let decoder = JSONDecoder()
            let content = try decoder.decode(
                [ContentPart].self,
                from: Data(self.contentJSON.utf8)
            )
            let toolCalls = try decoder.decode(
                [ToolCall].self,
                from: Data(self.toolCallsJSON.utf8)
            )
            let metadata = try decoder.decode(
                [String: JSONValue].self,
                from: Data(self.metadataJSON.utf8)
            )
            guard let role = Message.Role(rawValue: self.role) else {
                throw GRDBStorageError.malformedRow("unknown role: \(self.role)")
            }
            return Message(
                role: role,
                content: content,
                toolCalls: toolCalls,
                toolCallId: self.toolCallId,
                metadata: metadata,
                createdAt: Date(timeIntervalSinceReferenceDate: self.createdAt)
            )
        }
    }

    // MARK: - GRDBStorageError

    enum GRDBStorageError: Error, Equatable {
        case malformedRow(String)
    }

#endif
