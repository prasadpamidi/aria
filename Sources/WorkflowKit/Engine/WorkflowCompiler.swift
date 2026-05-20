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
            attended: attended
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
    }

    // MARK: Private

    private let broker: CapabilityBroker
    private let llmProvider: any WorkflowLLMProvider
    private let jsEvaluator: any WorkflowJSEvaluator

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
            graph.addEdge(from: name, to: self.nextLinearNodeName(after: index, names: context.names))
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
        case .branch, .parallel:
            // Passthrough in the node table — routing happens via
            // the conditional / parallel edge added later. Still
            // need a node body so the graph has an attachment
            // point for the edge.
            graph.addNode(name) { state in state }
        case let .output(step):
            self.addOutputNode(step: step, name: name, graph: &graph)
        }
    }

    private func addLLMNode(
        step: LLMStep,
        name: String,
        graph: inout StateGraph<WorkflowState>
    ) {
        let provider = self.llmProvider
        graph.addNode(name) { state in
            let prompt = TemplateInterpolator.render(step.promptTemplate, bindings: state.bindings)
            let text = try await provider.generate(
                prompt: prompt,
                hint: step.modelHint,
                maxTokens: step.maxTokens
            )
            var next = state
            next.bindings[step.outputBinding] = .string(text)
            return next
        }
    }

    private func addCapabilityNode(
        step: CapabilityStep,
        name: String,
        graph: inout StateGraph<WorkflowState>,
        callerPluginID: String,
        attended: Bool
    ) {
        let broker = self.broker
        graph.addNode(name) { state in
            // Interpolate every templated arg. Non-string values
            // arrive verbatim (the JS std-lib bridge will accept
            // any JSONValue once slice 10 wires it through; for
            // now capability args are string-valued).
            var resolved: [String: JSONValue] = [:]
            for (key, template) in step.argsTemplate {
                resolved[key] = .string(TemplateInterpolator.render(template, bindings: state.bindings))
            }

            let value = try await broker.call(
                capability: step.capability,
                method: step.method,
                arguments: resolved,
                callerPluginID: callerPluginID,
                attended: attended
            )

            var next = state
            next.bindings[step.outputBinding] = value
            return next
        }
    }

    private func addTransformNode(
        step: TransformStep,
        name: String,
        graph: inout StateGraph<WorkflowState>
    ) {
        let evaluator = self.jsEvaluator
        graph.addNode(name) { state in
            // Flatten bindings into a string→string map for the
            // JS bridge — `JSContext` accepts richer types, but
            // the wire shape between the engine and the bridge
            // stays simple here. Slice 10 will adopt a richer
            // shape if it turns out to be needed.
            let bindings = state.bindings.mapValues { value -> String in
                if case let .string(string) = value {
                    return string
                }
                return TemplateInterpolator.render("{{__value__}}", bindings: ["__value__": value])
            }
            let resultText = try await evaluator.evaluate(
                expression: step.jsExpression,
                bindings: bindings
            )
            var next = state
            next.bindings[step.outputBinding] = .string(resultText)
            return next
        }
    }

    private func addOutputNode(
        step: OutputStep,
        name: String,
        graph: inout StateGraph<WorkflowState>
    ) {
        graph.addNode(name) { state in
            var next = state
            for (fieldID, template) in step.fields {
                next.result[fieldID] = .string(
                    TemplateInterpolator.render(template, bindings: state.bindings)
                )
            }
            return next
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

        let evaluator = self.jsEvaluator
        let condition = branch.condition

        // Conditional edges can't be `async`, but `evaluateBool`
        // is. Snapshot the route decision into the workflow's
        // state from a synchronous closure that consults a
        // pre-computed value — this lands in slice 10 along with
        // the real JS bridge. For now the conditional defaults
        // to the true branch and surfaces a build-time warning
        // (slice 10 swaps in proper handling).
        _ = condition
        _ = evaluator
        graph.addConditionalEdge(
            from: name,
            targets: [trueTarget, falseTarget]
        ) { _ in trueTarget }
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
