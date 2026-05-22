import Foundation

// MARK: - Workflow

/// Top-level workflow record. Stored as JSON in GRDB
/// (`WorkflowStore` in slice 2) and lowered to
/// `Aria.StateGraph<WorkflowState>` at run time by
/// `WorkflowCompiler` (slice 5).
///
/// Nodes are stored as a flat ordered array, not a graph. For
/// purely-linear workflows (the common case in P0), `edges` is
/// empty and the runtime walks `nodes` in order. Branch + parallel
/// steps express their fan-out / fan-in via child id arrays inside
/// the step variants themselves — `edges` only carries layout /
/// override info for the graph view (slice 13).
public struct Workflow: Codable, Identifiable, Sendable, Equatable {
    // MARK: Lifecycle

    // swiftlint:disable:next function_parameter_count
    public init(
        id: UUID = UUID(),
        name: String,
        summary: String = "",
        inputSchema: InputSchema = .init(),
        outputSchema: OutputSchema = .init(),
        nodes: [WorkflowNode] = [],
        edges: [WorkflowEdge] = [],
        triggers: Set<Trigger> = [.manual],
        modelHint: ModelFamilyHint = .any,
        toolPolicy: ToolPolicy = .init(),
        memoryPolicy: MemoryPolicy = .init(),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        nodePositions: [String: NodePosition] = [:],
        parentWorkflowID: UUID? = nil,
        timeOfDayTags: Set<TimeOfDay> = []
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.inputSchema = inputSchema
        self.outputSchema = outputSchema
        self.nodes = nodes
        self.edges = edges
        self.triggers = triggers
        self.modelHint = modelHint
        self.toolPolicy = toolPolicy
        self.memoryPolicy = memoryPolicy
        // Round to millisecond precision so the JSON round-trip
        // through `.secondsSince1970` is bit-stable. Without this,
        // a fresh `Date()` carries microsecond precision that the
        // encoder→decoder pair sometimes loses in its low bits,
        // making Equatable comparisons against a re-decoded copy
        // flaky. Persistence metadata never needs sub-millisecond
        // precision in practice.
        self.createdAt = Self.roundedToMillisecond(createdAt)
        self.updatedAt = Self.roundedToMillisecond(updatedAt)
        self.nodePositions = nodePositions
        self.parentWorkflowID = parentWorkflowID
        self.timeOfDayTags = timeOfDayTags
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let positions = try container.decodeIfPresent(
            [String: NodePosition].self,
            forKey: .nodePositions
        ) ?? [:]
        let parent = try container.decodeIfPresent(UUID.self, forKey: .parentWorkflowID)
        let timeTags = try container.decodeIfPresent(
            Set<TimeOfDay>.self,
            forKey: .timeOfDayTags
        ) ?? []
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            name: container.decode(String.self, forKey: .name),
            summary: container.decode(String.self, forKey: .summary),
            inputSchema: container.decode(InputSchema.self, forKey: .inputSchema),
            outputSchema: container.decode(OutputSchema.self, forKey: .outputSchema),
            nodes: container.decode([WorkflowNode].self, forKey: .nodes),
            edges: container.decode([WorkflowEdge].self, forKey: .edges),
            triggers: container.decode(Set<Trigger>.self, forKey: .triggers),
            modelHint: container.decode(ModelFamilyHint.self, forKey: .modelHint),
            toolPolicy: container.decode(ToolPolicy.self, forKey: .toolPolicy),
            memoryPolicy: container.decode(MemoryPolicy.self, forKey: .memoryPolicy),
            createdAt: container.decode(Date.self, forKey: .createdAt),
            updatedAt: container.decode(Date.self, forKey: .updatedAt),
            nodePositions: positions,
            parentWorkflowID: parent,
            timeOfDayTags: timeTags
        )
    }

    // MARK: Public

    public let id: UUID
    public var name: String
    public var summary: String
    public var inputSchema: InputSchema
    public var outputSchema: OutputSchema
    public var nodes: [WorkflowNode]
    public var edges: [WorkflowEdge]
    public var triggers: Set<Trigger>
    public var modelHint: ModelFamilyHint
    public var toolPolicy: ToolPolicy
    public var memoryPolicy: MemoryPolicy
    public var createdAt: Date
    public var updatedAt: Date
    /// Per-node position overrides used by the graph editor.
    /// Keyed by `WorkflowNode.id.uuidString` so the JSON map
    /// stays human-readable. When a node has no entry,
    /// `WorkflowGraphLayout` supplies a default. Conditionally
    /// encoded — workflows that never visit the graph editor
    /// stay byte-identical to the pre-positions schema.
    public var nodePositions: [String: NodePosition]
    /// When a workflow was created by Remix-ing a prebuilt
    /// catalogue entry, this holds the source catalog entry's
    /// id. Surfaced in the library as "Based on: <name>" so
    /// the user can see lineage. `nil` for blank / hand-built
    /// workflows. Optional + decodeIfPresent for forward
    /// compatibility with workflows authored before this
    /// field existed.
    public var parentWorkflowID: UUID?

    /// "When is this workflow most useful" tags. Empty by
    /// default — Home's suggester treats unset == `.anytime` so
    /// existing prebuilt + user-authored workflows keep working
    /// without retroactive tagging. Authors / catalogue packs
    /// opt in via `timeOfDayTags: [.morning]` etc. Conditionally
    /// encoded so workflows that never set tags stay
    /// byte-identical to the pre-field schema.
    public var timeOfDayTags: Set<TimeOfDay>

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.id, forKey: .id)
        try container.encode(self.name, forKey: .name)
        try container.encode(self.summary, forKey: .summary)
        try container.encode(self.inputSchema, forKey: .inputSchema)
        try container.encode(self.outputSchema, forKey: .outputSchema)
        try container.encode(self.nodes, forKey: .nodes)
        try container.encode(self.edges, forKey: .edges)
        try container.encode(self.triggers, forKey: .triggers)
        try container.encode(self.modelHint, forKey: .modelHint)
        try container.encode(self.toolPolicy, forKey: .toolPolicy)
        try container.encode(self.memoryPolicy, forKey: .memoryPolicy)
        try container.encode(self.createdAt, forKey: .createdAt)
        try container.encode(self.updatedAt, forKey: .updatedAt)
        if !self.nodePositions.isEmpty {
            try container.encode(self.nodePositions, forKey: .nodePositions)
        }
        if let parent = self.parentWorkflowID {
            try container.encode(parent, forKey: .parentWorkflowID)
        }
        if !self.timeOfDayTags.isEmpty {
            try container.encode(self.timeOfDayTags, forKey: .timeOfDayTags)
        }
    }

    // MARK: Private

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case summary
        case inputSchema
        case outputSchema
        case nodes
        case edges
        case triggers
        case modelHint
        case toolPolicy
        case memoryPolicy
        case createdAt
        case updatedAt
        case nodePositions
        case parentWorkflowID
        case timeOfDayTags
    }

    private static func roundedToMillisecond(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1000).rounded() / 1000)
    }
}

// MARK: - NodePosition

/// Per-node position override for the graph editor. Stored
/// against `Workflow.nodePositions` keyed by the node's UUID
/// string. When a node has no entry, the renderer falls back
/// to the auto-computed position from `WorkflowGraphLayout`.
public struct NodePosition: Codable, Sendable, Hashable {
    // MARK: Lifecycle

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    // MARK: Public

    public var x: Double
    public var y: Double
}

// MARK: - WorkflowEdge

/// Explicit edge between two nodes. Used by the graph view to
/// position arrows and by `WorkflowCompiler` to handle non-linear
/// transitions (the linear-default case can omit edges entirely).
/// `metadata` carries free-form key/value pairs the editor uses
/// for layout overrides (slice 13).
public struct WorkflowEdge: Codable, Sendable, Equatable {
    // MARK: Lifecycle

    public init(from: UUID, to: UUID, metadata: [String: String] = [:]) {
        self.from = from
        self.to = to
        self.metadata = metadata
    }

    // MARK: Public

    public let from: UUID
    public let to: UUID
    public var metadata: [String: String]
}

// MARK: - ToolPolicy

/// Per-workflow allowlist for which capabilities + plugins the
/// runner may invoke. Mirrors the `CapabilityBroker`'s scope check
/// but at the workflow level — even if the user has granted a
/// plugin a capability globally, a workflow that doesn't list it
/// here can't fire it. Defends against a malicious template
/// import.
public struct ToolPolicy: Codable, Sendable, Equatable {
    // MARK: Lifecycle

    public init(
        allowedCapabilities: Set<CapabilityID> = [],
        allowedPlugins: Set<String> = []
    ) {
        self.allowedCapabilities = allowedCapabilities
        self.allowedPlugins = allowedPlugins
    }

    // MARK: Public

    public var allowedCapabilities: Set<CapabilityID>
    /// Plugin bundle identifiers (`so.aria.example.weather` etc.).
    public var allowedPlugins: Set<String>
}

// MARK: - MemoryPolicy

/// Memory isolation choice for the workflow's LLM steps. `.shared`
/// participates in the active chat thread (writes facts via
/// `RememberTool`, reads via `RAGMiddleware`). `.isolated` runs
/// against a dedicated thread id so the workflow doesn't leak
/// transient state into the user's main chat.
public struct MemoryPolicy: Codable, Sendable, Equatable {
    // MARK: Lifecycle

    public init(mode: Mode = .isolated, threadId: String = "workflow") {
        self.mode = mode
        self.threadId = threadId
    }

    // MARK: Public

    public enum Mode: String, Codable, Sendable {
        case isolated
        case shared
    }

    public var mode: Mode
    public var threadId: String
}
