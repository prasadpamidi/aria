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
    case pluginTool(PluginToolStep)
    case mcpTool(MCPToolStep)
    case transform(TransformStep)
    case branch(BranchStep)
    case parallel(ParallelStep)
    case loop(LoopStep)
    case output(OutputStep)
    /// Embed an AgentKit agent loop as a workflow step. The runner
    /// resolves a `SubAgentExecutor` (typically backed by
    /// `AgentRuntime`), runs the agent with the provided inputs,
    /// and binds the final answer back under `outputBinding`. Lets
    /// a mostly-deterministic workflow defer one step to the agentic
    /// mid-turn-tools loop without WorkflowKit duplicating loop
    /// machinery. Added in 0.2.0.
    case subAgent(SubAgentStep)

    // MARK: Lifecycle

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(Discriminator.self, forKey: .type)
        switch type {
        case .llm:
            self = try .llm(container.decode(LLMStep.self, forKey: .data))
        case .capability:
            self = try .capability(container.decode(CapabilityStep.self, forKey: .data))
        case .pluginTool:
            self = try .pluginTool(container.decode(PluginToolStep.self, forKey: .data))
        case .mcpTool:
            self = try .mcpTool(container.decode(MCPToolStep.self, forKey: .data))
        case .transform:
            self = try .transform(container.decode(TransformStep.self, forKey: .data))
        case .branch:
            self = try .branch(container.decode(BranchStep.self, forKey: .data))
        case .parallel:
            self = try .parallel(container.decode(ParallelStep.self, forKey: .data))
        case .loop:
            self = try .loop(container.decode(LoopStep.self, forKey: .data))
        case .output:
            self = try .output(container.decode(OutputStep.self, forKey: .data))
        case .subAgent:
            self = try .subAgent(container.decode(SubAgentStep.self, forKey: .data))
        }
    }

    // MARK: Public

    public var id: UUID {
        switch self {
        case let .llm(step): step.id
        case let .capability(step): step.id
        case let .pluginTool(step): step.id
        case let .mcpTool(step): step.id
        case let .transform(step): step.id
        case let .branch(step): step.id
        case let .parallel(step): step.id
        case let .loop(step): step.id
        case let .output(step): step.id
        case let .subAgent(step): step.id
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
        case let .pluginTool(step):
            try container.encode(Discriminator.pluginTool, forKey: .type)
            try container.encode(step, forKey: .data)
        case let .mcpTool(step):
            try container.encode(Discriminator.mcpTool, forKey: .type)
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
        case let .loop(step):
            try container.encode(Discriminator.loop, forKey: .type)
            try container.encode(step, forKey: .data)
        case let .output(step):
            try container.encode(Discriminator.output, forKey: .type)
            try container.encode(step, forKey: .data)
        case let .subAgent(step):
            try container.encode(Discriminator.subAgent, forKey: .type)
            try container.encode(step, forKey: .data)
        }
    }

    // MARK: Private

    // MARK: Codable

    private enum Discriminator: String, Codable {
        case llm
        case capability
        case pluginTool
        case mcpTool
        case transform
        case branch
        case parallel
        case loop
        case output
        case subAgent
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
/// `structuredOutputSchema` is present and non-empty, the runtime
/// dispatches through `WorkflowLLMProvider.generateStructured(...)`
/// — providers with native schema support (FoundationModels,
/// OpenAI function-calling) constrain the model with the schema
/// at decode time; the default impl falls back to text + lenient
/// JSON parse. The binding receives the structured `JSONValue`
/// directly so downstream templates can address fields with
/// `{{step.field}}`. Without `structuredOutputSchema` the raw
/// text binds as `.string(text)` under `outputBinding`.
public struct LLMStep: Codable, Sendable, Equatable {
    // MARK: Lifecycle

    public init(
        id: UUID = UUID(),
        promptTemplate: String,
        outputBinding: String = "text",
        structuredOutputSchema: String? = nil,
        modelHint: ModelFamilyHint = .any,
        maxTokens: Int? = nil,
        serverProviderID: UUID? = nil,
        mlxModelID: String? = nil,
        extraSkillIDs: Set<UUID> = [],
        disabledSkillIDs: Set<UUID> = [],
        attachmentBindings: [String] = [],
        requiredModalities: Set<ContentModality> = [],
        retryPolicy: RetryPolicy? = nil,
        timeout: Duration? = nil
    ) {
        self.id = id
        self.promptTemplate = promptTemplate
        self.outputBinding = outputBinding
        self.structuredOutputSchema = structuredOutputSchema
        self.modelHint = modelHint
        self.maxTokens = maxTokens
        self.serverProviderID = serverProviderID
        self.mlxModelID = mlxModelID
        self.extraSkillIDs = extraSkillIDs
        self.disabledSkillIDs = disabledSkillIDs
        self.attachmentBindings = attachmentBindings
        self.requiredModalities = requiredModalities
        self.retryPolicy = retryPolicy
        self.timeout = timeout
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.promptTemplate = try container.decode(String.self, forKey: .promptTemplate)
        self.outputBinding = try container.decode(String.self, forKey: .outputBinding)
        self.structuredOutputSchema = try container.decodeIfPresent(String.self, forKey: .structuredOutputSchema)
        self.modelHint = try container.decode(ModelFamilyHint.self, forKey: .modelHint)
        self.maxTokens = try container.decodeIfPresent(Int.self, forKey: .maxTokens)
        self.serverProviderID = try container.decodeIfPresent(UUID.self, forKey: .serverProviderID)
        self.mlxModelID = try container.decodeIfPresent(String.self, forKey: .mlxModelID)
        self.extraSkillIDs = try container.decodeIfPresent(Set<UUID>.self, forKey: .extraSkillIDs) ?? []
        self.disabledSkillIDs = try container.decodeIfPresent(Set<UUID>.self, forKey: .disabledSkillIDs) ?? []
        self.attachmentBindings = try container.decodeIfPresent([String].self, forKey: .attachmentBindings) ?? []
        self.requiredModalities = try container.decodeIfPresent(
            Set<ContentModality>.self,
            forKey: .requiredModalities
        ) ?? []
        self.retryPolicy = try container.decodeIfPresent(RetryPolicy.self, forKey: .retryPolicy)
        self.timeout = try container.decodeIfPresent(Duration.self, forKey: .timeout)
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
    /// Pointer into the app's `ServerProviderStore`. When set + the
    /// compiler was constructed with a matching
    /// `ServerLLMProviderResolver`, this step routes through the
    /// configured OpenAI / Anthropic / Gemini provider instead of
    /// the compiler's default (typically on-device
    /// FoundationModels). `nil` keeps the historical behaviour —
    /// run against the default provider — which is what every
    /// pre-Slice-2b workflow expects.
    public let serverProviderID: UUID?
    /// Hugging-Face-style model identifier from the MLX catalog
    /// (e.g. `mlx-community/Qwen2.5-1.5B-Instruct-4bit`). When set
    /// + the compiler was constructed with an
    /// `MLXLLMProviderResolver`, this step routes through the
    /// requested MLX model running on-device via `AriaMLX`. Lower
    /// precedence than `serverProviderID` — if both are set the
    /// server provider wins (the editor's picker only lets the
    /// user set one at a time).
    public let mlxModelID: String?

    /// Skills to expose to this step in addition to whatever the
    /// owning workflow's `enabledSkillIDs` declares. Empty by
    /// default — most steps inherit the workflow-level set as-is.
    public let extraSkillIDs: Set<UUID>

    /// Skills the workflow declares but that this specific step
    /// should NOT see. Higher precedence than the workflow set,
    /// so a workflow that enables `meeting-notes` globally can
    /// still hide it on a per-step basis when it's irrelevant.
    public let disabledSkillIDs: Set<UUID>

    /// Names of workflow bindings the runner should resolve into
    /// `ContentBlock` values and pass to the provider's
    /// `generateMultimodal(...)` call. Each referenced binding must
    /// decode as a `ContentBlock` (or array of them). Empty for the
    /// historical text-only path; the runner picks the right
    /// provider entry-point based on whether this is empty. Added in
    /// 0.2.0.
    public let attachmentBindings: [String]

    /// Optional explicit modality set the step asserts it needs. The
    /// compiler's capability validator unions this with the
    /// modalities discovered in `attachmentBindings` to drive the
    /// pre-flight check against the bound provider's
    /// `supportedModalities`. Use this when the binding payload is
    /// computed dynamically and you want the safety net regardless.
    /// Added in 0.2.0.
    public let requiredModalities: Set<ContentModality>

    /// Per-step retry policy. `nil` keeps the historical "one
    /// attempt, fail the run" behaviour for backwards compatibility.
    /// Set this to remove host-side retry loops around prose-leak,
    /// transient provider errors, rate limits, and timeouts. Added in
    /// 0.2.0.
    public let retryPolicy: RetryPolicy?

    /// Per-attempt timeout. `nil` means "wait as long as the
    /// provider takes" (today's behaviour). When set, the runner
    /// races the generate call against `Task.sleep(for: timeout)`
    /// and surfaces a timeout error that the `retryPolicy` can
    /// retry on. Added in 0.2.0.
    public let timeout: Duration?

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.id, forKey: .id)
        try container.encode(self.promptTemplate, forKey: .promptTemplate)
        try container.encode(self.outputBinding, forKey: .outputBinding)
        try container.encodeIfPresent(self.structuredOutputSchema, forKey: .structuredOutputSchema)
        try container.encode(self.modelHint, forKey: .modelHint)
        try container.encodeIfPresent(self.maxTokens, forKey: .maxTokens)
        try container.encodeIfPresent(self.serverProviderID, forKey: .serverProviderID)
        try container.encodeIfPresent(self.mlxModelID, forKey: .mlxModelID)
        if !self.extraSkillIDs.isEmpty {
            try container.encode(self.extraSkillIDs, forKey: .extraSkillIDs)
        }
        if !self.disabledSkillIDs.isEmpty {
            try container.encode(self.disabledSkillIDs, forKey: .disabledSkillIDs)
        }
        if !self.attachmentBindings.isEmpty {
            try container.encode(self.attachmentBindings, forKey: .attachmentBindings)
        }
        if !self.requiredModalities.isEmpty {
            try container.encode(self.requiredModalities, forKey: .requiredModalities)
        }
        try container.encodeIfPresent(self.retryPolicy, forKey: .retryPolicy)
        try container.encodeIfPresent(self.timeout, forKey: .timeout)
    }

    // MARK: Private

    private enum CodingKeys: String, CodingKey {
        case id
        case promptTemplate
        case outputBinding
        case structuredOutputSchema
        case modelHint
        case maxTokens
        case serverProviderID
        case mlxModelID
        case extraSkillIDs
        case disabledSkillIDs
        case attachmentBindings
        case requiredModalities
        case retryPolicy
        case timeout
    }
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

// MARK: - PluginToolStep

/// Deterministically invoke a user-installed JavaScript plugin
/// tool. Mirrors `CapabilityStep` for the native-capability
/// surface, but routes through the `JSToolProvider` runtime
/// rather than the `CapabilityBroker`. Bypasses the LLM, so
/// authors can chain a plugin into a workflow without paying
/// for a model turn or relying on the model to decide to call
/// it.
///
/// `pluginID` is the bundle's reverse-DNS identifier (the same
/// id the user authors in `JSPluginAuthoringScreen`).
/// `argsTemplate` values are templated strings interpolated
/// against the running bindings at run time; the resolved map
/// is the JSON input object the plugin's `call(input)` sees.
public struct PluginToolStep: Codable, Sendable, Equatable {
    // MARK: Lifecycle

    public init(
        id: UUID = UUID(),
        pluginID: String,
        argsTemplate: [String: String] = [:],
        outputBinding: String
    ) {
        self.id = id
        self.pluginID = pluginID
        self.argsTemplate = argsTemplate
        self.outputBinding = outputBinding
    }

    // MARK: Public

    public let id: UUID
    public let pluginID: String
    public let argsTemplate: [String: String]
    public let outputBinding: String
}

// MARK: - MCPToolStep

/// Call a tool on an external MCP (Model Context Protocol)
/// server over HTTPS. Mirrors `PluginToolStep`'s shape but
/// routes the call through a typed `MCPClient` instead of the
/// in-process JS plugin runtime. Auth (when needed) is bound to
/// a saved credential via `credentialID`; the engine resolves
/// the secret through an `MCPCredentialResolver` injected at
/// compile time — `WorkflowKit` never sees raw secrets.
///
/// `argsTemplate` values are interpolated against the running
/// bindings at run time, then passed to the server as the
/// tool's `arguments` object. The string output (concatenated
/// from the server's `text` content blocks) lands under
/// `outputBinding`.
public struct MCPToolStep: Codable, Sendable, Equatable {
    // MARK: Lifecycle

    public init(
        id: UUID = UUID(),
        serverURL: String,
        credentialID: UUID? = nil,
        toolName: String,
        argsTemplate: [String: String] = [:],
        outputBinding: String
    ) {
        self.id = id
        self.serverURL = serverURL
        self.credentialID = credentialID
        self.toolName = toolName
        self.argsTemplate = argsTemplate
        self.outputBinding = outputBinding
    }

    // MARK: Public

    public let id: UUID
    /// Endpoint to POST JSON-RPC envelopes to. Required — an
    /// empty URL surfaces `MCPError.invalidServerURL` at run
    /// time so the user gets a usable diagnostic instead of a
    /// silent skip.
    public let serverURL: String
    /// Optional reference into the credential vault. `nil` means
    /// "no auth header" — useful for MCP servers on a private
    /// network or that key-gate via an URL query parameter.
    public let credentialID: UUID?
    /// Tool name as the server advertises it. The step doesn't
    /// validate against the server's `tools/list` — invalid names
    /// surface as `MCPError.serverError` at call time so users
    /// who renamed a tool see the precise error.
    public let toolName: String
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
        falseBranch: [UUID] = [],
        joinNodeID: UUID? = nil
    ) {
        self.id = id
        self.condition = condition
        self.trueBranch = trueBranch
        self.falseBranch = falseBranch
        self.joinNodeID = joinNodeID
    }

    // MARK: Public

    public let id: UUID
    public let condition: String
    public let trueBranch: [UUID]
    public let falseBranch: [UUID]
    /// Node both branches converge to. After the chosen branch's
    /// last entry runs, control transfers here. When `nil`, the
    /// compiler falls back to the node-after-the-branch in
    /// workflow declaration order — which only does what the
    /// author wants when each branch list has exactly one entry
    /// and the next node is the merge point. Authors building
    /// multi-step branches should set this explicitly.
    public let joinNodeID: UUID?
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

// MARK: - LoopStep

/// While-loop control flow. Runs the body's ordered list of
/// node ids repeatedly while `condition` evaluates truthy.
/// `maxIterations` is a hard safety cap — the engine throws
/// `WorkflowEngineError.loopMaxIterationsExceeded` if reached
/// so a buggy predicate can't peg a thread forever.
/// `breakOn` is the optional "break out early" predicate
/// evaluated at the *end* of each iteration: when truthy, the
/// loop exits immediately (semantically equivalent to a
/// trailing `if (...) break;` inside the body).
/// `iterationBinding`, when set, exposes the current 0-indexed
/// iteration counter under that binding name so the body can
/// reference it (e.g. as `b.i` in JS).
///
/// Body nodes are siblings in `Workflow.nodes` — they're
/// excluded from the main chain at compile time and executed
/// inline by the loop. Branch / parallel / nested-loop / output
/// step types aren't allowed inside the body for P0; the engine
/// throws `loopBodyContainsUnsupportedNode` if encountered.
public struct LoopStep: Codable, Sendable, Equatable {
    // MARK: Lifecycle

    public init(
        id: UUID = UUID(),
        condition: String,
        body: [UUID] = [],
        maxIterations: Int = 1000,
        breakOn: String? = nil,
        iterationBinding: String? = nil
    ) {
        self.id = id
        self.condition = condition
        self.body = body
        self.maxIterations = maxIterations
        self.breakOn = breakOn
        self.iterationBinding = iterationBinding
    }

    // MARK: Public

    public let id: UUID
    public let condition: String
    public let body: [UUID]
    public let maxIterations: Int
    public let breakOn: String?
    public let iterationBinding: String?
}

// MARK: - OutputStep

/// Terminal node. `fields` maps each declared output id (per
/// `Workflow.outputSchema`) to a templated string the runtime
/// interpolates at finish time. The resolved map is the
/// workflow's return value to the AppIntent / library run sheet.
///
/// `renderModes` carries per-field presentation hints used by
/// the in-app result panel — markdown, code, voice, or the
/// default plain text. The map is sparse: a field id absent
/// from the map renders as `.plain`. Surfaces that don't
/// support voice / rich rendering (AppIntent return values,
/// x-callback URL payloads) ignore the modes entirely.
public struct OutputStep: Codable, Sendable, Equatable {
    // MARK: Lifecycle

    public init(
        id: UUID = UUID(),
        fields: [String: String],
        renderModes: [String: OutputRenderMode] = [:]
    ) {
        self.id = id
        self.fields = fields
        self.renderModes = renderModes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(UUID.self, forKey: .id)
        let fields = try container.decode([String: String].self, forKey: .fields)
        // `decodeIfPresent` on the renderModes key keeps every
        // pre-render-mode workflow decoding cleanly with an
        // empty render-mode map — i.e. plain-text everywhere.
        let modes = try container.decodeIfPresent(
            [String: OutputRenderMode].self,
            forKey: .renderModes
        ) ?? [:]
        self.init(id: id, fields: fields, renderModes: modes)
    }

    // MARK: Public

    public let id: UUID
    public let fields: [String: String]
    public let renderModes: [String: OutputRenderMode]

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.id, forKey: .id)
        try container.encode(self.fields, forKey: .fields)
        // Conditionally encoded so workflows that never set a
        // render mode stay byte-identical to the pre-field
        // schema in their on-disk + Codable form.
        if !self.renderModes.isEmpty {
            try container.encode(self.renderModes, forKey: .renderModes)
        }
    }

    // MARK: Private

    private enum CodingKeys: String, CodingKey {
        case id
        case fields
        case renderModes
    }
}

// MARK: - SubAgentStep

/// Embed an AgentKit agent loop as a workflow step. Added in 0.2.0
/// to bridge the deterministic single-shot workflow model with
/// AgentKit's multi-turn loop without duplicating agent-runner
/// machinery inside WorkflowKit. The runner resolves a
/// `SubAgentExecutor` (see `WorkflowLLMProvider.swift`) — typically
/// backed by `AgentRuntime` — runs the named agent definition with
/// the provided inputs, and binds the final answer (text +
/// optional structured payload) back under `outputBinding`.
///
/// The agent's own model selection, tool set, approval policy, and
/// memory are all owned by its `AgentDefinition`; this step just
/// names which one to invoke and how to thread the workflow's
/// running bindings into the agent's first user message.
public struct SubAgentStep: Codable, Sendable, Equatable {
    // MARK: Lifecycle

    public init(
        id: UUID = UUID(),
        agentDefinitionID: UUID,
        inputBindings: [String: String] = [:],
        outputBinding: String,
        maxSteps: Int? = nil,
        attended: Bool? = nil,
        retryPolicy: RetryPolicy? = nil,
        timeout: Duration? = nil
    ) {
        self.id = id
        self.agentDefinitionID = agentDefinitionID
        self.inputBindings = inputBindings
        self.outputBinding = outputBinding
        self.maxSteps = maxSteps
        self.attended = attended
        self.retryPolicy = retryPolicy
        self.timeout = timeout
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.agentDefinitionID = try container.decode(UUID.self, forKey: .agentDefinitionID)
        self.inputBindings = try container.decodeIfPresent(
            [String: String].self,
            forKey: .inputBindings
        ) ?? [:]
        self.outputBinding = try container.decode(String.self, forKey: .outputBinding)
        self.maxSteps = try container.decodeIfPresent(Int.self, forKey: .maxSteps)
        self.attended = try container.decodeIfPresent(Bool.self, forKey: .attended)
        self.retryPolicy = try container.decodeIfPresent(RetryPolicy.self, forKey: .retryPolicy)
        self.timeout = try container.decodeIfPresent(Duration.self, forKey: .timeout)
    }

    // MARK: Public

    public let id: UUID

    /// Stable id resolved through the host-provided
    /// `SubAgentExecutor` (typically maps to `AgentStore`).
    public let agentDefinitionID: UUID

    /// Workflow-binding → agent-input map. Values are interpolated
    /// against the running bindings using the same
    /// `{{name.field}}` syntax other steps use, then handed to the
    /// executor as a `[String: JSONValue]`. The executor builds
    /// the agent's first user message from these — typically
    /// concatenating them as labelled blocks, but the executor
    /// chooses the shape.
    public let inputBindings: [String: String]

    /// Where the agent's final answer lands. The executor returns
    /// `JSONValue.object({"text": "...", "structured": ...?})` —
    /// callers that just want the text can address it as
    /// `{{step.text}}`; structured answers as
    /// `{{step.structured.<field>}}`.
    public let outputBinding: String

    /// Override the agent definition's `maxSteps`. `nil` inherits
    /// the definition's value.
    public let maxSteps: Int?

    /// Override the run's `attended` flag for this agent only.
    /// `nil` inherits the workflow run's value (set by the
    /// caller of `WorkflowRunner.run(...)` / `runStreaming(...)`).
    public let attended: Bool?

    public let retryPolicy: RetryPolicy?
    public let timeout: Duration?

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.id, forKey: .id)
        try container.encode(self.agentDefinitionID, forKey: .agentDefinitionID)
        if !self.inputBindings.isEmpty {
            try container.encode(self.inputBindings, forKey: .inputBindings)
        }
        try container.encode(self.outputBinding, forKey: .outputBinding)
        try container.encodeIfPresent(self.maxSteps, forKey: .maxSteps)
        try container.encodeIfPresent(self.attended, forKey: .attended)
        try container.encodeIfPresent(self.retryPolicy, forKey: .retryPolicy)
        try container.encodeIfPresent(self.timeout, forKey: .timeout)
    }

    // MARK: Private

    private enum CodingKeys: String, CodingKey {
        case id
        case agentDefinitionID
        case inputBindings
        case outputBinding
        case maxSteps
        case attended
        case retryPolicy
        case timeout
    }
}
