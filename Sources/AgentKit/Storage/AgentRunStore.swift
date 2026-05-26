import Foundation

// MARK: - AgentRunStore

/// Persistence for `AgentRunRecord`s — the durable bookkeeping that
/// lets the app list resumable runs and route approvals after the
/// in-memory event stream is gone (e.g. across app kill).
///
/// File-per-run JSON under `Application Support/avyra-agent-runs/`.
/// Same rationale and concurrency model as `AgentStore`: low volume,
/// no GRDB dependency in the app target, `NSLock`-guarded I/O so the
/// off-main `CheckpointMiddleware` and the on-main runtime/UI can
/// both touch it safely.
public final class AgentRunStore: @unchecked Sendable {
    // MARK: Lifecycle

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public convenience init() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("avyra-agent-runs-\(UUID().uuidString)", isDirectory: true)
        try self.init(directory: tmp)
    }

    // MARK: Public

    /// Mint and persist a fresh run for `agentID`. Pass
    /// `threadId` to keep this run on an existing conversation
    /// (used by the run screen for follow-up turns); omit to
    /// mint a new run-scoped thread.
    @discardableResult
    public func create(
        agentID: UUID,
        inputSummary: String,
        threadId: String? = nil
    ) throws -> AgentRunRecord {
        let record = AgentRunRecord.start(
            agentID: agentID,
            inputSummary: inputSummary,
            threadId: threadId
        )
        try self.save(record)
        return record
    }

    /// Insert or replace a run record wholesale.
    public func save(_ record: AgentRunRecord) throws {
        let data = try AgentCodec.encode(record)
        try self.lock.withLock {
            try data.write(to: self.url(for: record.id), options: .atomic)
        }
    }

    public func load(id: UUID) throws -> AgentRunRecord? {
        try self.lock.withLock {
            try self.loadUnlocked(id: id)
        }
    }

    /// All runs, most-recently-updated first.
    public func list() throws -> [AgentRunRecord] {
        try self.lock.withLock {
            try self.allUnlocked().sorted { $0.updatedAt > $1.updatedAt }
        }
    }

    /// Runs the user can pick back up (`paused` / `awaitingApproval`),
    /// most-recently-updated first.
    public func listResumable() throws -> [AgentRunRecord] {
        try self.list().filter(\.isResumable)
    }

    /// Atomic read-modify-write. Loads the record, applies `mutate`,
    /// bumps `updatedAt`, and persists — all under one lock so a
    /// checkpoint write and a status change can't clobber each other.
    /// Returns the updated record, or `nil` if the run is gone.
    @discardableResult
    public func update(
        id: UUID,
        _ mutate: (inout AgentRunRecord) -> Void
    ) throws -> AgentRunRecord? {
        try self.lock.withLock {
            guard var record = try self.loadUnlocked(id: id) else {
                return nil
            }
            mutate(&record)
            record.updatedAt = Self.roundedNow()
            try AgentCodec.encode(record).write(to: self.url(for: id), options: .atomic)
            return record
        }
    }

    public func delete(id: UUID) throws {
        try self.lock.withLock {
            let url = self.url(for: id)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    public func deleteAll() throws {
        try self.lock.withLock {
            for file in try self.jsonFiles() {
                try FileManager.default.removeItem(at: file)
            }
        }
    }

    // MARK: Private

    private let directory: URL
    private let lock = NSLock()

    private static func roundedNow() -> Date {
        Date(timeIntervalSince1970: (Date().timeIntervalSince1970 * 1000).rounded() / 1000)
    }

    private func url(for id: UUID) -> URL {
        self.directory.appendingPathComponent("\(id.uuidString).json")
    }

    private func loadUnlocked(id: UUID) throws -> AgentRunRecord? {
        let url = self.url(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return try AgentCodec.decode(AgentRunRecord.self, from: Data(contentsOf: url))
    }

    private func allUnlocked() throws -> [AgentRunRecord] {
        try self.jsonFiles().compactMap { file in
            guard let data = try? Data(contentsOf: file) else {
                return nil
            }
            return try? AgentCodec.decode(AgentRunRecord.self, from: data)
        }
    }

    private func jsonFiles() throws -> [URL] {
        try FileManager.default
            .contentsOfDirectory(at: self.directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
    }
}
