import Foundation
import WorkflowKit

// MARK: - AgentDefinition

/// Top-level, user-editable definition of an **agent** — the
/// persistable sibling to `Workflow`. Where a `Workflow` is a
/// deterministic recipe (a flat list of steps the runtime walks),
/// an `AgentDefinition` is a *goal you delegate*: a persona +
/// guardrails + a tool surface that `AgentCompiler` lowers into a
/// live `Aria.Agent` (a streaming tool-calling loop) at run time.
///
/// Stored as a single JSON blob in `AgentStore` (GRDB), mirroring
/// `Workflow`/`WorkflowStore`. `parentAgentID` records lineage when
/// a definition was cloned from a default — surfaced in the UI as
/// "Based on: <name>".
///
/// All tool references are stored *by id* and resolved at compile
/// time through the same resolver seams Workflows use
/// (`CapabilityBroker`, `JSToolProvider`, `MCPServerStore`,
/// `SkillProvider`). Nothing executable is serialized.
public struct AgentDefinition: Codable, Identifiable, Sendable, Equatable {
    // MARK: Lifecycle

    // swiftlint:disable:next function_parameter_count
    public init(
        id: UUID = UUID(),
        name: String,
        summary: String = "",
        systemPrompt: String = "",
        maxSteps: Int = 10,
        modelHint: ModelFamilyHint = .foundationModels,
        serverProviderID: UUID? = nil,
        mlxModelID: String? = nil,
        enabledCapabilities: Set<CapabilityID> = [],
        enabledCapabilityMethods: [String: Set<String>] = [:],
        enabledPluginIDs: Set<String> = [],
        enabledMCPToolRefs: Set<MCPToolRef> = [],
        enabledWorkflowIDs: Set<UUID> = [],
        enabledSkillIDs: Set<UUID> = [],
        approvalPolicy: ApprovalPolicy = .autonomous,
        triggers: Set<Trigger> = [.manual],
        timeOfDayTags: Set<TimeOfDay> = [],
        suggestedActions: [String] = [],
        recommendsStrongerModel: Bool = false,
        parentAgentID: UUID? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.systemPrompt = systemPrompt
        self.maxSteps = maxSteps
        self.modelHint = modelHint
        self.serverProviderID = serverProviderID
        self.mlxModelID = mlxModelID
        self.enabledCapabilities = enabledCapabilities
        self.enabledCapabilityMethods = enabledCapabilityMethods
        self.enabledPluginIDs = enabledPluginIDs
        self.enabledMCPToolRefs = enabledMCPToolRefs
        self.enabledWorkflowIDs = enabledWorkflowIDs
        self.enabledSkillIDs = enabledSkillIDs
        self.approvalPolicy = approvalPolicy
        self.triggers = triggers
        self.timeOfDayTags = timeOfDayTags
        self.suggestedActions = suggestedActions
        self.recommendsStrongerModel = recommendsStrongerModel
        self.parentAgentID = parentAgentID
        // Round to millisecond precision so the JSON round-trip
        // through `.secondsSince1970` stays bit-stable and Equatable
        // comparisons against a re-decoded copy don't flake on the
        // low bits of microsecond precision. Same rationale as
        // `Workflow.roundedToMillisecond`.
        self.createdAt = Self.roundedToMillisecond(createdAt)
        self.updatedAt = Self.roundedToMillisecond(updatedAt)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            name: container.decode(String.self, forKey: .name),
            summary: container.decodeIfPresent(String.self, forKey: .summary) ?? "",
            systemPrompt: container.decodeIfPresent(String.self, forKey: .systemPrompt) ?? "",
            maxSteps: container.decodeIfPresent(Int.self, forKey: .maxSteps) ?? 10,
            modelHint: container.decodeIfPresent(ModelFamilyHint.self, forKey: .modelHint) ?? .foundationModels,
            serverProviderID: container.decodeIfPresent(UUID.self, forKey: .serverProviderID),
            mlxModelID: container.decodeIfPresent(String.self, forKey: .mlxModelID),
            enabledCapabilities: container.decodeIfPresent(Set<CapabilityID>.self, forKey: .enabledCapabilities) ?? [],
            enabledCapabilityMethods: container.decodeIfPresent(
                [String: Set<String>].self,
                forKey: .enabledCapabilityMethods
            ) ?? [:],
            enabledPluginIDs: container.decodeIfPresent(Set<String>.self, forKey: .enabledPluginIDs) ?? [],
            enabledMCPToolRefs: container.decodeIfPresent(Set<MCPToolRef>.self, forKey: .enabledMCPToolRefs) ?? [],
            enabledWorkflowIDs: container.decodeIfPresent(Set<UUID>.self, forKey: .enabledWorkflowIDs) ?? [],
            enabledSkillIDs: container.decodeIfPresent(Set<UUID>.self, forKey: .enabledSkillIDs) ?? [],
            approvalPolicy: container.decodeIfPresent(ApprovalPolicy.self, forKey: .approvalPolicy) ?? .autonomous,
            triggers: container.decodeIfPresent(Set<Trigger>.self, forKey: .triggers) ?? [.manual],
            timeOfDayTags: container.decodeIfPresent(Set<TimeOfDay>.self, forKey: .timeOfDayTags) ?? [],
            suggestedActions: container.decodeIfPresent([String].self, forKey: .suggestedActions) ?? [],
            recommendsStrongerModel: container.decodeIfPresent(Bool.self, forKey: .recommendsStrongerModel) ?? false,
            parentAgentID: container.decodeIfPresent(UUID.self, forKey: .parentAgentID),
            createdAt: container.decode(Date.self, forKey: .createdAt),
            updatedAt: container.decode(Date.self, forKey: .updatedAt)
        )
    }

    // MARK: Public

    public let id: UUID
    public var name: String
    public var summary: String

    /// Persona / instructions the agent runs under. Skills layer on
    /// top of this at compile time (`SkillPromptBuilder`).
    public var systemPrompt: String
    /// Hard cap on tool-calling rounds. Maps to `AgentConfig.maxSteps`.
    public var maxSteps: Int

    // Model routing — identical inputs to `LLMStep`. Resolution
    // precedence (server → MLX → FoundationModels default) lives in
    // `AvyraProviderResolver`.
    public var modelHint: ModelFamilyHint
    public var serverProviderID: UUID?
    public var mlxModelID: String?

    /// Tool surface — all by id, resolved at compile time.
    public var enabledCapabilities: Set<CapabilityID>
    /// Optional per-capability method allowlist, keyed by
    /// `CapabilityID.rawValue`. Empty entry (or missing key) ==
    /// "all supported methods". Lets a read-only agent expose
    /// `calendar.listEvents` without `calendar.createEvent`.
    public var enabledCapabilityMethods: [String: Set<String>]
    public var enabledPluginIDs: Set<String>
    public var enabledMCPToolRefs: Set<MCPToolRef>
    /// Workflows exposed to the agent as deterministic sub-routine
    /// tools (agents-call-workflows). Resolved via
    /// `WorkflowToolKitBuilder`.
    public var enabledWorkflowIDs: Set<UUID>
    public var enabledSkillIDs: Set<UUID>

    /// Human-in-the-loop posture. `.autonomous` lets the agent act
    /// directly; `.proposeThenConfirm` keeps side-effecting actions
    /// out of the agent's tool surface entirely — the agent proposes,
    /// the host executes on approval.
    public var approvalPolicy: ApprovalPolicy

    public var triggers: Set<Trigger>
    public var timeOfDayTags: Set<TimeOfDay>

    /// Tap-to-load starter prompts shown above the composer on the
    /// agent's empty state. The agent author curates these (per-agent
    /// rather than the chat surface's shared set) so they match what
    /// each agent is actually good at. Empty `[]` hides the chip row.
    public var suggestedActions: [String]

    /// Hints to the UI that this agent's value depends on real
    /// multi-step reasoning — so Apple Intelligence (small,
    /// on-device) will produce noticeably worse results than a
    /// server LLM (Claude / GPT) or a larger on-device MLX model
    /// (Gemma 4, Qwen 3.5). The catalogue detail screen + builder
    /// surface a recommendation banner when this is `true` and the
    /// resolved provider is Apple Intelligence. Empirically true
    /// for agents whose loop is "observe → decide → act → re-observe"
    /// rather than a fixed scripted sequence — small models can do
    /// the scripted sequences fine but fail at the iterative kind.
    public var recommendsStrongerModel: Bool

    /// Source definition id when this was cloned from a default or
    /// another agent. `nil` for blank / hand-built agents.
    public var parentAgentID: UUID?

    public var createdAt: Date
    public var updatedAt: Date

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.id, forKey: .id)
        try container.encode(self.name, forKey: .name)
        try container.encode(self.summary, forKey: .summary)
        try container.encode(self.systemPrompt, forKey: .systemPrompt)
        try container.encode(self.maxSteps, forKey: .maxSteps)
        try container.encode(self.modelHint, forKey: .modelHint)
        try container.encodeIfPresent(self.serverProviderID, forKey: .serverProviderID)
        try container.encodeIfPresent(self.mlxModelID, forKey: .mlxModelID)
        if !self.enabledCapabilities.isEmpty {
            try container.encode(self.enabledCapabilities, forKey: .enabledCapabilities)
        }
        if !self.enabledCapabilityMethods.isEmpty {
            try container.encode(self.enabledCapabilityMethods, forKey: .enabledCapabilityMethods)
        }
        if !self.enabledPluginIDs.isEmpty {
            try container.encode(self.enabledPluginIDs, forKey: .enabledPluginIDs)
        }
        if !self.enabledMCPToolRefs.isEmpty {
            try container.encode(self.enabledMCPToolRefs, forKey: .enabledMCPToolRefs)
        }
        if !self.enabledWorkflowIDs.isEmpty {
            try container.encode(self.enabledWorkflowIDs, forKey: .enabledWorkflowIDs)
        }
        if !self.enabledSkillIDs.isEmpty {
            try container.encode(self.enabledSkillIDs, forKey: .enabledSkillIDs)
        }
        if self.approvalPolicy != .autonomous {
            try container.encode(self.approvalPolicy, forKey: .approvalPolicy)
        }
        try container.encode(self.triggers, forKey: .triggers)
        if !self.timeOfDayTags.isEmpty {
            try container.encode(self.timeOfDayTags, forKey: .timeOfDayTags)
        }
        if !self.suggestedActions.isEmpty {
            try container.encode(self.suggestedActions, forKey: .suggestedActions)
        }
        if self.recommendsStrongerModel {
            try container.encode(self.recommendsStrongerModel, forKey: .recommendsStrongerModel)
        }
        try container.encodeIfPresent(self.parentAgentID, forKey: .parentAgentID)
        try container.encode(self.createdAt, forKey: .createdAt)
        try container.encode(self.updatedAt, forKey: .updatedAt)
    }

    // MARK: Private

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case summary
        case systemPrompt
        case maxSteps
        case modelHint
        case serverProviderID
        case mlxModelID
        case enabledCapabilities
        case enabledCapabilityMethods
        case enabledPluginIDs
        case enabledMCPToolRefs
        case enabledWorkflowIDs
        case enabledSkillIDs
        case approvalPolicy
        case triggers
        case timeOfDayTags
        case suggestedActions
        case recommendsStrongerModel
        case parentAgentID
        case createdAt
        case updatedAt
    }

    private static func roundedToMillisecond(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1000).rounded() / 1000)
    }
}

// MARK: - AgentDefinition helpers

extension AgentDefinition {
    /// Methods the agent may call for `capability`, honoring the
    /// allowlist. `nil` means "all supported methods" (the factory
    /// expands it against the capability's declared methods).
    public func allowedMethods(for capability: CapabilityID) -> Set<String>? {
        guard let methods = self.enabledCapabilityMethods[capability.rawValue], !methods.isEmpty else {
            return nil
        }
        return methods
    }
}

// MARK: - MCPToolRef

/// Reference to a single tool on a registered MCP server. Stored on
/// `AgentDefinition.enabledMCPToolRefs`; resolved against
/// `MCPServerStore` at compile time. `serverID` matches the
/// `MCPServer.id` in the registry; `toolName` is the tool's wire
/// name (the public name is derived at compile time).
public struct MCPToolRef: Codable, Sendable, Hashable {
    // MARK: Lifecycle

    public init(serverID: UUID, toolName: String) {
        self.serverID = serverID
        self.toolName = toolName
    }

    // MARK: Public

    public var serverID: UUID
    public var toolName: String
}
