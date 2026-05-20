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
        updatedAt: Date = Date()
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

    // MARK: Private

    private static func roundedToMillisecond(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1000).rounded() / 1000)
    }
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
