import Aria
import Foundation

// MARK: - WorkflowCompiler

/// Lowers a user-authored `Workflow` into a runnable
/// `Aria.CompiledStateGraph<WorkflowState>`. The editor never
/// speaks StateGraph directly — it edits `Workflow` JSON, persists
/// to GRDB, and the compiler does the lowering on demand.
///
/// One node per `WorkflowNode`, joined by edges that follow node
/// declaration order for linear segments. Branch / parallel
/// shapes use the StateGraph's conditional + parallel edge
/// primitives so we inherit parallel-fanout + reducer support
/// for free (Slice 5b will register state-aware reducers; for
/// P0 the default last-write-wins behavior is sufficient).
///
/// The compiler is a pure transform — no I/O, no async. It takes
/// injection seams for the runtime dependencies (LLM provider,
/// capability broker, JS evaluator) so the produced graph is
/// closed over the exact instances tests want to assert on.
public struct WorkflowCompiler: Sendable {
    // MARK: Lifecycle

    // swiftlint:disable:next function_parameter_count
    public init(
        broker: CapabilityBroker,
        llmProvider: any WorkflowLLMProvider,
        jsEvaluator: any WorkflowJSEvaluator = ThrowingJSEvaluator(),
        pluginToolBroker: (any PluginToolBroker)? = nil,
        serverLLMResolver: ServerLLMProviderResolver? = nil,
        mlxLLMResolver: MLXLLMProviderResolver? = nil,
        mcpCredentialResolver: MCPCredentialResolver? = nil,
        skillResolver: WorkflowSkillResolver? = nil,
        subAgentExecutor: (any SubAgentExecutor)? = nil,
        retryClassifier: any WorkflowRetryClassifier = DefaultWorkflowRetryClassifier()
    ) {
        self.broker = broker
        self.llmProvider = llmProvider
        self.jsEvaluator = jsEvaluator
        self.pluginToolBroker = pluginToolBroker
        self.serverLLMResolver = serverLLMResolver
        self.mlxLLMResolver = mlxLLMResolver
        self.mcpCredentialResolver = mcpCredentialResolver
        self.skillResolver = skillResolver
        self.subAgentExecutor = subAgentExecutor
        self.retryClassifier = retryClassifier
    }

    // MARK: Public

    /// Build a `CompiledStateGraph` for the workflow. Throws
    /// `StateGraphError.invalidGraph` if the workflow's node
    /// list is empty or terminal-less, surfacing those cases
    /// during the editor's pre-save validation pass.
    public func compile(
        _ workflow: Workflow,
        callerPluginID: String,
        attended: Bool = true,
        eventSink: (any WorkflowEventSink)? = nil
    ) throws -> CompiledStateGraph<WorkflowState> {
        guard !workflow.nodes.isEmpty else {
            throw StateGraphError.invalidGraph("Workflow has no nodes")
        }

        var graph = StateGraph<WorkflowState>()
        let names = workflow.nodes.map(\.id.uuidString)
        let loopBodyNodeIDs = Self.computeLoopBodyNodeIDs(workflow: workflow)
        let context = EmissionContext(
            workflow: workflow,
            names: names,
            callerPluginID: callerPluginID,
            attended: attended,
            branchExitOverrides: Self.computeBranchExitOverrides(workflow: workflow),
            loopBodyNodeIDs: loopBodyNodeIDs,
            eventSink: eventSink
        )

        for (index, node) in workflow.nodes.enumerated() {
            // Loop-body nodes don't emit their own state-graph
            // nodes — they execute inline inside the parent
            // loop's executor. Skipping them here keeps the
            // graph DAG-shaped (no cycles back to the loop's
            // entry) while preserving the bodies' positions
            // in the source workflow for the editor's sake.
            if context.loopBodyNodeIDs.contains(names[index]) {
                continue
            }
            self.emit(node: node, index: index, context: context, graph: &graph)
        }
        guard let entry = Self.firstNonBodyNodeName(
            names: names,
            loopBodyNodeIDs: loopBodyNodeIDs
        ) else {
            throw StateGraphError.invalidGraph("Workflow has only loop-body nodes")
        }
        graph.setEntry(entry)
        return try graph.build()
    }

    // MARK: Internal

    /// Bundle of per-compile inputs that flow through the
    /// emission helpers. Packaging them keeps individual helper
    /// signatures under the project's 6-parameter cap.
    struct EmissionContext {
        let workflow: Workflow
        let names: [String]
        let callerPluginID: String
        let attended: Bool
        /// Map of node-id-string → target-name for branch list
        /// entries. When a node is reachable as a branch arm, its
        /// outbound linear-default transition must skip past the
        /// other branch arm and go straight to the merge point.
        /// Computed once at `compile` time; consumed by `emit`'s
        /// linear-default path.
        let branchExitOverrides: [String: String]
        /// Node-id-strings that belong to a `LoopStep.body`. These
        /// don't get their own state-graph nodes; the loop's
        /// executor runs them inline. The next-linear edge logic
        /// must skip past them when finding the successor of a
        /// non-body node.
        let loopBodyNodeIDs: Set<String>
        /// Optional sink for per-step lifecycle events. When non-
        /// nil, every instrumented `add*Node` wraps its closure
        /// so the UI can render live progress. Default (nil)
        /// keeps the engine zero-overhead for non-streaming
        /// callers (AppIntent, URL scheme, programmatic runs).
        let eventSink: (any WorkflowEventSink)?
    }

    /// Visible to the per-node extension in
    /// `WorkflowCompiler+Nodes.swift`. Effectively private to
    /// the compiler's lowering — the extension lives in the same
    /// target.
    let broker: CapabilityBroker
    let llmProvider: any WorkflowLLMProvider
    let jsEvaluator: any WorkflowJSEvaluator
    let pluginToolBroker: (any PluginToolBroker)?
    /// Optional bridge to the app's `ServerProviderStore` +
    /// `CredentialStore`. When set, LLM steps whose
    /// `serverProviderID` resolves return a configured HTTP
    /// client; otherwise the step falls back to `llmProvider`.
    let serverLLMResolver: ServerLLMProviderResolver?
    /// Optional bridge to the app's `MLXModelManager`. When set,
    /// LLM steps whose `mlxModelID` names a downloaded MLX model
    /// run against an `AriaMLX`-backed adapter; otherwise the step
    /// falls back to `llmProvider`. Lower precedence than
    /// `serverLLMResolver` — server providers win when both are
    /// set on the same step.
    let mlxLLMResolver: MLXLLMProviderResolver?
    /// Optional bridge to the app's `CredentialStore` for MCP
    /// tool steps. When `nil`, MCP steps that name a
    /// `credentialID` fail closed with
    /// `MCPError.missingCredential`; steps with no credentialID
    /// (private-network servers) still run.
    let mcpCredentialResolver: MCPCredentialResolver?
    /// Optional bridge to the app's `SkillProvider`. When set,
    /// LLM steps prepend skill descriptions + bodies to their
    /// prompt based on the workflow + step's effective skill
    /// set. `nil` means workflow LLM steps see no skills, which
    /// matches pre-skills behaviour.
    let skillResolver: WorkflowSkillResolver?
    /// Optional bridge to the app's `AgentRuntime` (or any
    /// equivalent) for executing `SubAgentStep` nodes. When `nil`,
    /// any `SubAgentStep` in the workflow fails at run time with
    /// `WorkflowEngineError.subAgentExecutorUnavailable`. Added in
    /// 0.2.0.
    let subAgentExecutor: (any SubAgentExecutor)?
    /// Classifier the per-step retry executor consults to decide
    /// whether a thrown error matches one of the retry policy's
    /// `retryOn` categories. Defaults to
    /// `DefaultWorkflowRetryClassifier`, which handles the
    /// universal decode-failure / timeout / cancellation cases.
    /// Hosts compose vendor-specific classifiers on top via
    /// `DefaultWorkflowRetryClassifier.compose(_:)`. Added in 0.2.0.
    let retryClassifier: any WorkflowRetryClassifier

    /// Stable, namespaced binding key for a branch's predicate
    /// outcome. Underscore-prefixed so it doesn't collide with
    /// user-chosen `outputBinding` names (which can't start with
    /// an underscore in practice — they're surface API).
    static func branchResultBindingKey(branchID: UUID) -> String {
        "__branch.\(branchID.uuidString)"
    }

    // MARK: - Instrumentation

    /// Wrap a node closure with `WorkflowRunEvent` emission.
    /// Each instrumented step bookends its work with
    /// `stepStarted` / `stepCompleted` (or `stepFailed`); the
    /// completed event carries the value the step landed under
    /// `outputBinding` so the run UI can render it without
    /// walking the bindings map itself.
    static func instrument(
        nodeID: UUID,
        outputBinding: String?,
        sink: (any WorkflowEventSink)?,
        work: @escaping @Sendable (WorkflowState) async throws -> WorkflowState
    ) -> @Sendable (WorkflowState) async throws -> WorkflowState {
        { state in
            await sink?.emit(.stepStarted(nodeID: nodeID))
            do {
                let next = try await work(state)
                let value = outputBinding.flatMap { next.bindings[$0] }
                await sink?.emit(.stepCompleted(
                    nodeID: nodeID,
                    outputBinding: outputBinding,
                    value: value
                ))
                return next
            } catch {
                await sink?.emit(.stepFailed(
                    nodeID: nodeID,
                    error: error.localizedDescription
                ))
                throw error
            }
        }
    }

    // MARK: Private

    /// Build the branch-exit override map. For each branch step,
    /// each id in its true / false arm gets mapped to the
    /// branch's `joinNodeID` (when set) or the next-after-branch
    /// in workflow declaration order (the implicit join). This
    /// lets the `default:` linear-edge code in `emit` skip past
    /// sibling branch arms straight to the merge point.
    /// Union of every `LoopStep.body` ID. Body nodes are
    /// excluded from state-graph emission and from the
    /// next-linear edge calculation — their lifecycle is owned
    /// entirely by the parent loop's inline executor.
    private static func computeLoopBodyNodeIDs(workflow: Workflow) -> Set<String> {
        var ids: Set<String> = []
        for node in workflow.nodes {
            if case let .loop(loop) = node {
                for bodyID in loop.body {
                    ids.insert(bodyID.uuidString)
                }
            }
        }
        return ids
    }

    /// First non-body node name in declaration order — used as
    /// the graph's entry point. A workflow whose only nodes are
    /// loop-body nodes has no usable entry.
    private static func firstNonBodyNodeName(
        names: [String],
        loopBodyNodeIDs: Set<String>
    ) -> String? {
        names.first { !loopBodyNodeIDs.contains($0) }
    }

    private static func computeBranchExitOverrides(
        workflow: Workflow
    ) -> [String: String] {
        var overrides: [String: String] = [:]
        let names = workflow.nodes.map(\.id.uuidString)
        for (index, node) in workflow.nodes.enumerated() {
            guard case let .branch(branch) = node else {
                continue
            }
            let armIDs = Set(branch.trueBranch + branch.falseBranch)
            let joinName: String = {
                if let explicit = branch.joinNodeID,
                   let joinIndex = workflow.nodes.firstIndex(where: { $0.id == explicit }) {
                    return names[joinIndex]
                }
                // Implicit join: the first node after the branch
                // that ISN'T one of the branch's arms. Falling off
                // the end means the only successor is `.end`.
                let firstNonArm = ((index + 1)..<workflow.nodes.count)
                    .first { !armIDs.contains(workflow.nodes[$0].id) }
                guard let firstNonArm else {
                    return StateGraph<WorkflowState>.end
                }
                return names[firstNonArm]
            }()
            for armEntry in armIDs {
                overrides[armEntry.uuidString] = joinName
            }
        }
        return overrides
    }

    /// Emit one workflow node into the graph: install the node
    /// body and wire its outgoing transition. Split out of
    /// `compile` to keep both functions under the project's
    /// 40-line body cap.
    private func emit(
        node: WorkflowNode,
        index: Int,
        context: EmissionContext,
        graph: inout StateGraph<WorkflowState>
    ) {
        let name = context.names[index]
        self.addNode(node: node, name: name, graph: &graph, context: context)
        switch node {
        case let .branch(branch):
            self.wireBranch(branch: branch, name: name, context: context, graph: &graph)
        case let .parallel(parallel):
            self.wireParallel(
                parallel: parallel,
                name: name,
                fallbackJoin: self.nextLinearNodeName(after: index, context: context),
                graph: &graph
            )
        case .output:
            graph.addEdge(from: name, to: StateGraph<WorkflowState>.end)
        default:
            // Branch-arm entries skip to the branch's join point
            // rather than falling through to the next sibling.
            if let override = context.branchExitOverrides[name] {
                graph.addEdge(from: name, to: override)
            } else {
                graph.addEdge(from: name, to: self.nextLinearNodeName(after: index, context: context))
            }
        }
    }

    // MARK: - Node emission

    private func addNode(
        node: WorkflowNode,
        name: String,
        graph: inout StateGraph<WorkflowState>,
        context: EmissionContext
    ) {
        switch node {
        case let .llm(step):
            self.addLLMNode(
                step: step,
                workflow: context.workflow,
                name: name,
                graph: &graph,
                sink: context.eventSink
            )
        case let .capability(step):
            self.addCapabilityNode(
                step: step,
                name: name,
                graph: &graph,
                callerPluginID: context.callerPluginID,
                attended: context.attended,
                sink: context.eventSink
            )
        case let .pluginTool(step):
            self.addPluginToolNode(
                step: step,
                name: name,
                graph: &graph,
                sink: context.eventSink
            )
        case let .mcpTool(step):
            self.addMCPToolNode(
                step: step,
                name: name,
                graph: &graph,
                sink: context.eventSink
            )
        case let .transform(step):
            self.addTransformNode(step: step, name: name, graph: &graph, sink: context.eventSink)
        case let .branch(branch):
            self.addBranchPredicateNode(
                branch: branch,
                name: name,
                graph: &graph,
                sink: context.eventSink
            )
        case .parallel:
            // Parallel passthrough — the fan-out / fan-in edge
            // does the work. Still need a node body for the
            // graph's attachment point.
            graph.addNode(name) { state in state }
        case let .loop(step):
            let bodyNodes = step.body.compactMap { id in
                context.workflow.nodes.first(where: { $0.id == id })
            }
            self.addLoopNode(
                step: step,
                bodyNodes: bodyNodes,
                name: name,
                graph: &graph,
                callerPluginID: context.callerPluginID,
                attended: context.attended,
                sink: context.eventSink
            )
        case let .output(step):
            self.addOutputNode(step: step, name: name, graph: &graph, sink: context.eventSink)
        case let .subAgent(step):
            self.addSubAgentNode(
                step: step,
                name: name,
                graph: &graph,
                attended: context.attended,
                sink: context.eventSink
            )
        }
    }

    // MARK: - Edge wiring

    private func wireBranch(
        branch: BranchStep,
        name: String,
        context _: EmissionContext,
        graph: inout StateGraph<WorkflowState>
    ) {
        // Map the first id in each branch list to its compiled
        // node name. P0 supports linear "then-list / else-list"
        // branches; the cross-references are validated at graph
        // build time and surface as `StateGraphError.invalidGraph`
        // if a referenced id isn't in the workflow.
        let trueTarget = branch.trueBranch.first?.uuidString ?? StateGraph<WorkflowState>.end
        let falseTarget = branch.falseBranch.first?.uuidString ?? StateGraph<WorkflowState>.end
        let bindingKey = Self.branchResultBindingKey(branchID: branch.id)

        graph.addConditionalEdge(
            from: name,
            targets: [trueTarget, falseTarget]
        ) { state in
            // The branch predicate node ran first and stored the
            // boolean outcome in the binding map. Default to the
            // false branch on missing or non-bool values so a
            // mis-typed predicate fails closed.
            if case let .bool(value) = state.bindings[bindingKey], value {
                return trueTarget
            }
            return falseTarget
        }
    }

    private func wireParallel(
        parallel: ParallelStep,
        name: String,
        fallbackJoin: String,
        graph: inout StateGraph<WorkflowState>
    ) {
        let branches = parallel.children.map(\.uuidString)
        graph.addParallelEdge(
            from: name,
            branches: branches,
            joinAt: fallbackJoin
        )
    }

    /// Pick the next node to transition to when a step ends.
    /// Skips past loop-body nodes (they don't have their own
    /// state-graph nodes). Falls off the end → `.end` sentinel.
    private func nextLinearNodeName(
        after index: Int,
        context: EmissionContext
    ) -> String {
        var nextIndex = index + 1
        while nextIndex < context.names.count {
            let candidate = context.names[nextIndex]
            if !context.loopBodyNodeIDs.contains(candidate) {
                return candidate
            }
            nextIndex += 1
        }
        return StateGraph<WorkflowState>.end
    }
}
