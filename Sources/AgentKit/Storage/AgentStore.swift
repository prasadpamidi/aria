import Foundation

// MARK: - AgentStore

/// Persistence for `AgentDefinition`s — the agent analog of
/// `WorkflowStore`. Backed by one JSON file per agent under
/// `Application Support/avyra-agents/<id>.json`.
///
/// The app target doesn't link GRDB directly (only AriaApple /
/// WorkflowKit do), and agents are low-volume (a handful of defaults
/// + user-authored), so a file-per-agent store keeps the feature
/// app-side with zero new dependencies and stays trivially
/// inspectable on disk — the same approach the skills system uses
/// for `avyra-skills/<uuid>/SKILL.md`.
///
/// `@unchecked Sendable`: file I/O is guarded by an `NSLock` so reads
/// and writes are safe from any task (the runtime compiles off-main
/// while the UI reads on-main), matching `WorkflowStore`'s
/// any-task-safe contract.
public final class AgentStore: @unchecked Sendable {
    // MARK: Lifecycle

    /// Open (creating if needed) the agent store rooted at
    /// `directory`. Production passes
    /// `Application Support/avyra-agents`.
    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Fresh, isolated store in a unique temp directory. Used by
    /// unit tests and previews.
    public convenience init() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("avyra-agents-\(UUID().uuidString)", isDirectory: true)
        try self.init(directory: tmp)
    }

    // MARK: Public

    /// Lightweight row for list views — avoids decoding every blob
    /// just to render a name. Mirrors `WorkflowStore.Summary`.
    public struct Summary: Sendable, Equatable {
        public let id: UUID
        public let name: String
        public let summary: String
        public let updatedAt: Date
        /// Non-nil when this agent was cloned from another (a default
        /// or a user agent) — drives the "Based on" lineage label.
        public let parentAgentID: UUID?
    }

    /// Insert or update. Trusts the caller's `updatedAt` (so tests
    /// can assert deterministic values), same as `WorkflowStore.save`.
    public func save(_ agent: AgentDefinition) throws {
        let data = try AgentCodec.encode(agent)
        try self.lock.withLock {
            try data.write(to: self.url(for: agent.id), options: .atomic)
        }
    }

    /// Load one agent by id. `nil` when absent rather than throwing —
    /// the "deleted while a stale id lingers" path is non-exceptional.
    public func load(id: UUID) throws -> AgentDefinition? {
        try self.lock.withLock {
            try self.loadUnlocked(id: id)
        }
    }

    /// All agents, most-recently-updated first.
    public func list() throws -> [Summary] {
        try self.lock.withLock {
            let files = try self.jsonFiles()
            let summaries = files.compactMap { file -> Summary? in
                guard let data = try? Data(contentsOf: file),
                      let def = try? AgentCodec.decode(AgentDefinition.self, from: data) else {
                    return nil
                }
                return Summary(
                    id: def.id,
                    name: def.name,
                    summary: def.summary,
                    updatedAt: def.updatedAt,
                    parentAgentID: def.parentAgentID
                )
            }
            return summaries.sorted { $0.updatedAt > $1.updatedAt }
        }
    }

    /// Delete by id. No-op when absent.
    public func delete(id: UUID) throws {
        try self.lock.withLock {
            let url = self.url(for: id)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Convenience for tests + dev-mode "clear all agents".
    public func deleteAll() throws {
        try self.lock.withLock {
            for file in try self.jsonFiles() {
                try FileManager.default.removeItem(at: file)
            }
        }
    }

    /// Deep-copy an agent into a new, editable user agent. Records
    /// lineage via `parentAgentID` and suffixes the name with
    /// " Copy" — the agent analog of Workflow Remix.
    @discardableResult
    public func clone(from id: UUID) throws -> AgentDefinition {
        guard let source = try self.load(id: id) else {
            throw AgentStoreError.notFound(id)
        }
        let now = Date()
        let copy = AgentDefinition(
            id: UUID(),
            name: "\(source.name) Copy",
            summary: source.summary,
            systemPrompt: source.systemPrompt,
            maxSteps: source.maxSteps,
            modelHint: source.modelHint,
            serverProviderID: source.serverProviderID,
            mlxModelID: source.mlxModelID,
            enabledCapabilities: source.enabledCapabilities,
            enabledCapabilityMethods: source.enabledCapabilityMethods,
            enabledPluginIDs: source.enabledPluginIDs,
            enabledMCPToolRefs: source.enabledMCPToolRefs,
            enabledWorkflowIDs: source.enabledWorkflowIDs,
            enabledSkillIDs: source.enabledSkillIDs,
            approvalPolicy: source.approvalPolicy,
            triggers: source.triggers,
            timeOfDayTags: source.timeOfDayTags,
            parentAgentID: source.id,
            createdAt: now,
            updatedAt: now
        )
        try self.save(copy)
        return copy
    }

    // MARK: Private

    private let directory: URL
    private let lock = NSLock()

    private func url(for id: UUID) -> URL {
        self.directory.appendingPathComponent("\(id.uuidString).json")
    }

    private func loadUnlocked(id: UUID) throws -> AgentDefinition? {
        let url = self.url(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return try AgentCodec.decode(AgentDefinition.self, from: Data(contentsOf: url))
    }

    private func jsonFiles() throws -> [URL] {
        try FileManager.default
            .contentsOfDirectory(at: self.directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
    }
}

// MARK: - AgentStoreError

public enum AgentStoreError: Error, Sendable, Equatable {
    case notFound(UUID)
}
