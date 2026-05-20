import Aria
import Foundation

// MARK: - WorkflowCompiler node-emission helpers

/// Per-node graph emission. Lives in an extension so the primary
/// `WorkflowCompiler` declaration stays under the project's
/// type-body length budget. The split is purely organisational —
/// every method here is fileprivate to the compiler's lowering
/// path and isn't part of the public surface.
extension WorkflowCompiler {
    func addLLMNode(
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

    func addCapabilityNode(
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

    func addTransformNode(
        step: TransformStep,
        name: String,
        graph: inout StateGraph<WorkflowState>
    ) {
        let evaluator = self.jsEvaluator
        graph.addNode(name) { state in
            let result = try await evaluator.evaluate(
                expression: step.jsExpression,
                bindings: state.bindings
            )
            var next = state
            next.bindings[step.outputBinding] = result
            return next
        }
    }

    func addOutputNode(
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

    /// Branch passthrough: evaluate the predicate against the
    /// running bindings *before* the conditional edge runs, and
    /// stash the bool under a hidden binding the edge consults.
    /// This is the dance that lets us run async JS evaluation
    /// inside a synchronous `addConditionalEdge` route closure.
    func addBranchPredicateNode(
        branch: BranchStep,
        name: String,
        graph: inout StateGraph<WorkflowState>
    ) {
        let evaluator = self.jsEvaluator
        let condition = branch.condition
        let bindingKey = WorkflowCompiler.branchResultBindingKey(branchID: branch.id)
        graph.addNode(name) { state in
            let outcome = try await evaluator.evaluateBool(
                expression: condition,
                bindings: state.bindings
            )
            var next = state
            next.bindings[bindingKey] = .bool(outcome)
            return next
        }
    }
}
