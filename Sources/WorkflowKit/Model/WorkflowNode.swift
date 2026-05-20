import Foundation

// MARK: - WorkflowNode

/// One step in a workflow. Discriminated-union design so each
/// variant carries exactly the data its execution path needs,
/// without optional sprawl. The compiler (slice 5) walks an array
/// of these and emits one `Aria.StateGraph` node per variant; the
/// editor (slice 12) maps each variant to a step-card shape.
///
/// `Codable` uses a typed-key form (`{ "type": "...", "data":
/// {...} }`) so we never need to inspect ambiguous keys to
/// recover the variant. The discriminator strings are part of the
/// persisted format — renaming a case is a migration concern.
public enum WorkflowNode: Codable, Sendable, Identifiable, Equatable {
    case llm(LLMStep)
    case capability(CapabilityStep)
    case transform(TransformStep)
    case branch(BranchStep)
    case parallel(ParallelStep)
    case output(OutputStep)

    // MARK: Lifecycle

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(Discriminator.self, forKey: .type)
        switch type {
        case .llm:
            self = try .llm(container.decode(LLMStep.self, forKey: .data))
        case .capability:
            self = try .capability(container.decode(CapabilityStep.self, forKey: .data))
        case .transform:
            self = try .transform(container.decode(TransformStep.self, forKey: .data))
        case .branch:
            self = try .branch(container.decode(BranchStep.self, forKey: .data))
        case .parallel:
            self = try .parallel(container.decode(ParallelStep.self, forKey: .data))
        case .output:
            self = try .output(container.decode(OutputStep.self, forKey: .data))
        }
    }

    // MARK: Public

    public var id: UUID {
        switch self {
        case let .llm(step): step.id
        case let .capability(step): step.id
        case let .transform(step): step.id
        case let .branch(step): step.id
        case let .parallel(step): step.id
        case let .output(step): step.id
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .llm(step):
            try container.encode(Discriminator.llm, forKey: .type)
            try container.encode(step, forKey: .data)
        case let .capability(step):
            try container.encode(Discriminator.capability, forKey: .type)
            try container.encode(step, forKey: .data)
        case let .transform(step):
            try container.encode(Discriminator.transform, forKey: .type)
            try container.encode(step, forKey: .data)
        case let .branch(step):
            try container.encode(Discriminator.branch, forKey: .type)
            try container.encode(step, forKey: .data)
        case let .parallel(step):
            try container.encode(Discriminator.parallel, forKey: .type)
            try container.encode(step, forKey: .data)
        case let .output(step):
            try container.encode(Discriminator.output, forKey: .type)
            try container.encode(step, forKey: .data)
        }
    }

    // MARK: Private

    // MARK: Codable

    private enum Discriminator: String, Codable {
        case llm, capability, transform, branch, parallel, output
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case data
    }
}

// MARK: - LLMStep

/// One agent turn. `promptTemplate` interpolates against the
/// workflow's running bindings using the `{{stepId.field}}` syntax
/// (resolved by `TemplateInterpolator` in slice 5). When
/// `structuredOutputSchema` is present, the runtime asks the model
/// for a `@Generable`-style structured response and binds each
/// field of the result; otherwise the raw text becomes
/// `<stepId>.text`.
public struct LLMStep: Codable, Sendable, Equatable {
    // MARK: Lifecycle

    public init(
        id: UUID = UUID(),
        promptTemplate: String,
        outputBinding: String = "text",
        structuredOutputSchema: String? = nil,
        modelHint: ModelFamilyHint = .any,
        maxTokens: Int? = nil
    ) {
        self.id = id
        self.promptTemplate = promptTemplate
        self.outputBinding = outputBinding
        self.structuredOutputSchema = structuredOutputSchema
        self.modelHint = modelHint
        self.maxTokens = maxTokens
    }

    // MARK: Public

    public let id: UUID
    public let promptTemplate: String
    /// Slot in `WorkflowState.bindings` where the model's reply
    /// lands. Templates downstream reference it as `{{name}}`.
    /// Defaults to `"text"` so a single LLM step in a linear
    /// workflow can be referenced as `{{text}}` without extra
    /// configuration.
    public let outputBinding: String
    /// JSONSchema-as-string. Slice 5 parses + binds field by field.
    public let structuredOutputSchema: String?
    public let modelHint: ModelFamilyHint
    public let maxTokens: Int?
}

// MARK: - CapabilityStep

/// Call into the `CapabilityBroker` (native cap or JS plugin
/// adapter). `argsTemplate` values are templated strings;
/// `outputBinding` names the slot in workflow state where the
/// return value lands.
public struct CapabilityStep: Codable, Sendable, Equatable {
    // MARK: Lifecycle

    public init(
        id: UUID = UUID(),
        capability: CapabilityID,
        method: String,
        argsTemplate: [String: String] = [:],
        outputBinding: String
    ) {
        self.id = id
        self.capability = capability
        self.method = method
        self.argsTemplate = argsTemplate
        self.outputBinding = outputBinding
    }

    // MARK: Public

    public let id: UUID
    public let capability: CapabilityID
    /// Method on the capability — e.g. `"eventsToday"`,
    /// `"recentSteps"`. Capability impls enumerate which methods
    /// they accept; unknown methods fail at run time with a
    /// typed error rather than silently no-oping.
    public let method: String
    public let argsTemplate: [String: String]
    public let outputBinding: String
}

// MARK: - TransformStep

/// Run a small JS expression against the running bindings to
/// reshape data. Power-user escape hatch for the cases where a
/// dedicated capability would be overkill (e.g. "extract
/// `events[0].title`"). Bounded by the same `JSContext` sandbox
/// the JS plugin runtime uses, so untrusted templated workflows
/// can't escape.
public struct TransformStep: Codable, Sendable, Equatable {
    // MARK: Lifecycle

    public init(
        id: UUID = UUID(),
        jsExpression: String,
        outputBinding: String
    ) {
        self.id = id
        self.jsExpression = jsExpression
        self.outputBinding = outputBinding
    }

    // MARK: Public

    public let id: UUID
    public let jsExpression: String
    public let outputBinding: String
}

// MARK: - BranchStep

/// Conditional fork. `condition` is a JS expression that evaluates
/// against the running bindings and must return a boolean; the
/// two branches are ordered lists of node ids to execute. State
/// after the branch is the union of bindings produced by the
/// taken path.
public struct BranchStep: Codable, Sendable, Equatable {
    // MARK: Lifecycle

    public init(
        id: UUID = UUID(),
        condition: String,
        trueBranch: [UUID] = [],
        falseBranch: [UUID] = []
    ) {
        self.id = id
        self.condition = condition
        self.trueBranch = trueBranch
        self.falseBranch = falseBranch
    }

    // MARK: Public

    public let id: UUID
    public let condition: String
    public let trueBranch: [UUID]
    public let falseBranch: [UUID]
}

// MARK: - ParallelStep

/// Run multiple child nodes concurrently. Lowered to
/// `Aria.StateGraph`'s parallel-step primitive. Children inherit
/// the parent's bindings snapshot; their output bindings get
/// merged back when all children complete (last writer wins for
/// any overlap — workflows shouldn't deliberately collide).
public struct ParallelStep: Codable, Sendable, Equatable {
    // MARK: Lifecycle

    public init(id: UUID = UUID(), children: [UUID]) {
        self.id = id
        self.children = children
    }

    // MARK: Public

    public let id: UUID
    public let children: [UUID]
}

// MARK: - OutputStep

/// Terminal node. `fields` maps each declared output id (per
/// `Workflow.outputSchema`) to a templated string the runtime
/// interpolates at finish time. The resolved map is the
/// workflow's return value to the AppIntent / library run sheet.
public struct OutputStep: Codable, Sendable, Equatable {
    // MARK: Lifecycle

    public init(id: UUID = UUID(), fields: [String: String]) {
        self.id = id
        self.fields = fields
    }

    // MARK: Public

    public let id: UUID
    public let fields: [String: String]
}
