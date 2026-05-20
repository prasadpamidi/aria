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

    public init(
        broker: CapabilityBroker,
        llmProvider: any WorkflowLLMProvider,
        jsEvaluator: any WorkflowJSEvaluator = ThrowingJSEvaluator()
    ) {
        self.broker = broker
        self.llmProvider = llmProvider
        self.jsEvaluator = jsEvaluator
    }

    // MARK: Public

    /// Build a `CompiledStateGraph` for the workflow. Throws
    /// `StateGraphError.invalidGraph` if the workflow's node
    /// list is empty or terminal-less, surfacing those cases
    /// during the editor's pre-save validation pass.
    public func compile(
        _ workflow: Workflow,
        callerPluginID: String,
        attended: Bool = true
    ) throws -> CompiledStateGraph<WorkflowState> {
        guard !workflow.nodes.isEmpty else {
            throw StateGraphError.invalidGraph("Workflow has no nodes")
        }

        var graph = StateGraph<WorkflowState>()
        let names = workflow.nodes.map(\.id.uuidString)
        let context = EmissionContext(
            workflow: workflow,
            names: names,
            callerPluginID: callerPluginID,
            attended: attended,
            branchExitOverrides: Self.computeBranchExitOverrides(workflow: workflow)
        )

        for (index, node) in workflow.nodes.enumerated() {
            self.emit(node: node, index: index, context: context, graph: &graph)
        }
        graph.setEntry(names[0])
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
    }

    /// Visible to the per-node extension in
    /// `WorkflowCompiler+Nodes.swift`. Effectively private to
    /// the compiler's lowering — the extension lives in the same
    /// target.
    let broker: CapabilityBroker
    let llmProvider: any WorkflowLLMProvider
    let jsEvaluator: any WorkflowJSEvaluator

    /// Stable, namespaced binding key for a branch's predicate
    /// outcome. Underscore-prefixed so it doesn't collide with
    /// user-chosen `outputBinding` names (which can't start with
    /// an underscore in practice — they're surface API).
    static func branchResultBindingKey(branchID: UUID) -> String {
        "__branch.\(branchID.uuidString)"
    }

    // MARK: Private

    /// Build the branch-exit override map. For each branch step,
    /// each id in its true / false arm gets mapped to the
    /// branch's `joinNodeID` (when set) or the next-after-branch
    /// in workflow declaration order (the implicit join). This
    /// lets the `default:` linear-edge code in `emit` skip past
    /// sibling branch arms straight to the merge point.
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
                fallbackJoin: self.nextLinearNodeName(after: index, names: context.names),
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
                graph.addEdge(from: name, to: self.nextLinearNodeName(after: index, names: context.names))
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
            self.addLLMNode(step: step, name: name, graph: &graph)
        case let .capability(step):
            self.addCapabilityNode(
                step: step,
                name: name,
                graph: &graph,
                callerPluginID: context.callerPluginID,
                attended: context.attended
            )
        case let .transform(step):
            self.addTransformNode(step: step, name: name, graph: &graph)
        case let .branch(branch):
            self.addBranchPredicateNode(branch: branch, name: name, graph: &graph)
        case .parallel:
            // Parallel passthrough — the fan-out / fan-in edge
            // does the work. Still need a node body for the
            // graph's attachment point.
            graph.addNode(name) { state in state }
        case let .output(step):
            self.addOutputNode(step: step, name: name, graph: &graph)
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
    /// Falls off the end of the workflow → `.end` sentinel.
    private func nextLinearNodeName(after index: Int, names: [String]) -> String {
        let next = index + 1
        return next < names.count ? names[next] : StateGraph<WorkflowState>.end
    }
}
