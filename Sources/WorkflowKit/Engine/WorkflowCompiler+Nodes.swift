import Aria
import Foundation

// MARK: - WorkflowCompiler node-emission helpers

/// Per-node graph emission. Lives in an extension so the primary
/// `WorkflowCompiler` declaration stays under the project's
/// type-body length budget. The split is purely organisational —
/// every method here is fileprivate to the compiler's lowering
/// path and isn't part of the public surface.
extension WorkflowCompiler {
    // swiftlint:disable:next function_parameter_count
    func addLLMNode(
        step: LLMStep,
        workflow: Workflow,
        name: String,
        graph: inout StateGraph<WorkflowState>,
        sink: (any WorkflowEventSink)?
    ) {
        let defaultProvider = self.llmProvider
        let serverResolver = self.serverLLMResolver
        let mlxResolver = self.mlxLLMResolver
        let skillResolver = self.skillResolver
        let classifier = self.retryClassifier
        let skillIDs = WorkflowSkillSet.effective(workflow: workflow, step: step)
        graph.addNode(name, WorkflowCompiler.instrument(
            nodeID: step.id,
            outputBinding: step.outputBinding,
            sink: sink
        ) { state in
            let rendered = TemplateInterpolator.render(step.promptTemplate, bindings: state.bindings)
            let prompt = await WorkflowCompiler.augmentPromptWithSkills(
                rendered,
                skillIDs: skillIDs,
                resolver: skillResolver
            )
            let provider = await WorkflowCompiler.resolveLLMProvider(
                for: step,
                default: defaultProvider,
                serverResolver: serverResolver,
                mlxResolver: mlxResolver
            )
            await WorkflowCompiler.bestEffortPrewarm(provider)

            // The executor handles retry, timeout, streaming
            // dispatch (when both the caller AND provider opt in),
            // multimodal dispatch, and the structured-vs-text
            // routing. `allowStreaming` is true only when a sink
            // is present (i.e. `runStreaming(...)` is the call
            // path) and the resolved provider advertises
            // streaming structured output — otherwise we keep the
            // historical single-yield behaviour.
            let plan = LLMStepExecutor.Plan(
                stepID: step.id,
                outputBinding: step.outputBinding,
                promptTemplate: step.promptTemplate,
                modelHint: step.modelHint,
                maxTokens: step.maxTokens,
                structuredOutputSchema: step.structuredOutputSchema,
                attachmentBindings: step.attachmentBindings,
                requiredModalities: step.requiredModalities,
                retryPolicy: step.retryPolicy,
                timeout: step.timeout,
                allowStreaming: sink != nil
                    && provider.capabilities.supportsStreamingStructured
            )
            let bindingValue = try await LLMStepExecutor.execute(
                plan: plan,
                prompt: prompt,
                bindings: state.bindings,
                provider: provider,
                classifier: classifier,
                sink: sink
            )
            var next = state
            next.bindings[step.outputBinding] = bindingValue
            return next
        })
    }

    /// Prepend the resolved skill block to the step's rendered
    /// prompt. Workflow LLM steps are single-shot — there's no
    /// tool loop and no `load_skill` path — so every requested
    /// skill (whether `alwaysInline` or not) is inlined directly
    /// into the prompt.
    static func augmentPromptWithSkills(
        _ prompt: String,
        skillIDs: Set<UUID>,
        resolver: WorkflowSkillResolver?
    ) async -> String {
        guard let resolver, !skillIDs.isEmpty else {
            return prompt
        }
        let block = await resolver(skillIDs)
        if block.text.isEmpty {
            return prompt
        }
        return "\(block.text)\n\n\(prompt)"
    }

    /// Fire the provider's optional warm-up hook. Errors are
    /// swallowed by design — a failed prewarm shouldn't kill the
    /// step before the user even sees the real `generate` error.
    /// The on-device adapters use this to load weights into
    /// memory; the server clients inherit the no-op default.
    static func bestEffortPrewarm(_ provider: any WorkflowLLMProvider) async {
        do {
            try await provider.prewarm()
        } catch {
            // Intentionally swallowed; surfaces via `generate`
            // if the same underlying issue is real.
        }
    }

    /// Pick the provider to run an `LLMStep` against. Precedence:
    ///   1. If the step names a `serverProviderID` AND a
    ///      `serverResolver` is wired AND it returns non-nil,
    ///      use that — server providers win.
    ///   2. Else if the step names an `mlxModelID` AND an
    ///      `mlxResolver` is wired AND it returns non-nil,
    ///      use that — on-device MLX model.
    ///   3. Otherwise fall back to the compiler default (typically
    ///      Apple Intelligence / FoundationModels).
    /// The fallback is intentional — the editor flags steps whose
    /// provider or model has been deleted / uninstalled, so by the
    /// time a run hits this path the user has either accepted the
    /// fallback or been warned.
    static func resolveLLMProvider(
        for step: LLMStep,
        default defaultProvider: any WorkflowLLMProvider,
        serverResolver: ServerLLMProviderResolver?,
        mlxResolver: MLXLLMProviderResolver?
    ) async -> any WorkflowLLMProvider {
        if let id = step.serverProviderID, let serverResolver,
           let resolved = await serverResolver(id) {
            return resolved
        }
        if let modelID = step.mlxModelID, let mlxResolver,
           let resolved = await mlxResolver(modelID) {
            return resolved
        }
        return defaultProvider
    }

    func addCapabilityNode(
        step: CapabilityStep,
        name: String,
        graph: inout StateGraph<WorkflowState>,
        callerPluginID: String,
        attended: Bool,
        sink: (any WorkflowEventSink)?
    ) {
        let broker = self.broker
        graph.addNode(name, WorkflowCompiler.instrument(
            nodeID: step.id,
            outputBinding: step.outputBinding,
            sink: sink
        ) { state in
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
        })
    }

    /// Compile an MCP tool step into the graph. The MCP client is
    /// constructed fresh per call — the engine doesn't pool
    /// connections, since MCP servers are addressed per-step and
    /// the auth (when present) can change between turns. The
    /// resolver hop happens inside the node closure so a
    /// rotated credential is picked up on the next run without
    /// recompiling the workflow.
    func addMCPToolNode(
        step: MCPToolStep,
        name: String,
        graph: inout StateGraph<WorkflowState>,
        sink: (any WorkflowEventSink)?
    ) {
        let resolver = self.mcpCredentialResolver
        graph.addNode(name, WorkflowCompiler.instrument(
            nodeID: step.id,
            outputBinding: step.outputBinding,
            sink: sink
        ) { state in
            let text = try await WorkflowCompiler.executeMCPTool(
                step: step,
                state: state,
                resolver: resolver
            )
            var next = state
            next.bindings[step.outputBinding] = .string(text)
            return next
        })
    }

    /// Shared MCP tool execution path used by both the top-level
    /// graph node AND the loop-body executor. Extracted so the
    /// (URL parse → credential resolve → arg interpolate →
    /// client.callTool) sequence lives in one place; the two
    /// callers just thread their state through.
    ///
    /// `serverURL` and `toolName` are run through the template
    /// engine alongside `argsTemplate` so workflows can take
    /// either at runtime via the input schema — without this,
    /// a step authored as `serverURL: "{{input.serverURL}}"`
    /// would hit `URL(string:)` with the raw template string
    /// and fail with `invalidServerURL` even when the user did
    /// supply a valid URL in the input form.
    static func executeMCPTool(
        step: MCPToolStep,
        state: WorkflowState,
        resolver: MCPCredentialResolver?
    ) async throws -> String {
        let resolvedServerURL = TemplateInterpolator
            .render(step.serverURL, bindings: state.bindings)
            .trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: resolvedServerURL),
              url.scheme != nil else {
            // Surface the post-interpolation value in the error
            // so the user sees what we actually tried to dial,
            // not the original `{{input.…}}` template they wrote.
            throw MCPError.invalidServerURL(resolvedServerURL)
        }
        let credential: MCPCredential?
        if let credentialID = step.credentialID {
            guard let resolver else {
                throw MCPError.missingCredential(credentialID)
            }
            guard let resolved = await resolver(credentialID) else {
                throw MCPError.missingCredential(credentialID)
            }
            credential = resolved
        } else {
            credential = nil
        }
        var arguments: [String: JSONValue] = [:]
        for (key, template) in step.argsTemplate {
            arguments[key] = .string(
                TemplateInterpolator.render(template, bindings: state.bindings)
            )
        }
        let resolvedToolName = TemplateInterpolator
            .render(step.toolName, bindings: state.bindings)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let client = MCPClient(serverURL: url, credential: credential)
        return try await client.callTool(name: resolvedToolName, arguments: arguments)
    }

    func addPluginToolNode(
        step: PluginToolStep,
        name: String,
        graph: inout StateGraph<WorkflowState>,
        sink: (any WorkflowEventSink)?
    ) {
        let broker = self.pluginToolBroker
        graph.addNode(name, WorkflowCompiler.instrument(
            nodeID: step.id,
            outputBinding: step.outputBinding,
            sink: sink
        ) { state in
            guard let broker else {
                throw WorkflowEngineError.pluginToolBrokerUnavailable
            }
            // Interpolate every templated arg into the input
            // object. Same pattern as capability args — string-
            // typed templates today; richer typing arrives once
            // the JS std-lib bridge surfaces structured `JSONValue`
            // templating across the board.
            var resolved: [String: JSONValue] = [:]
            for (key, template) in step.argsTemplate {
                resolved[key] = .string(
                    TemplateInterpolator.render(template, bindings: state.bindings)
                )
            }
            let value = try await broker.invoke(
                pluginID: step.pluginID,
                input: .object(resolved)
            )
            var next = state
            next.bindings[step.outputBinding] = value
            return next
        })
    }

    func addTransformNode(
        step: TransformStep,
        name: String,
        graph: inout StateGraph<WorkflowState>,
        sink: (any WorkflowEventSink)?
    ) {
        let evaluator = self.jsEvaluator
        graph.addNode(name, WorkflowCompiler.instrument(
            nodeID: step.id,
            outputBinding: step.outputBinding,
            sink: sink
        ) { state in
            let result = try await evaluator.evaluate(
                expression: step.jsExpression,
                bindings: state.bindings
            )
            var next = state
            next.bindings[step.outputBinding] = result
            return next
        })
    }

    func addOutputNode(
        step: OutputStep,
        name: String,
        graph: inout StateGraph<WorkflowState>,
        sink: (any WorkflowEventSink)?
    ) {
        graph.addNode(name, WorkflowCompiler.instrument(
            nodeID: step.id,
            outputBinding: nil,
            sink: sink
        ) { state in
            var next = state
            for (fieldID, template) in step.fields {
                next.result[fieldID] = .string(
                    TemplateInterpolator.render(template, bindings: state.bindings)
                )
            }
            return next
        })
    }

    /// Inline-execution loop. The whole loop (predicate check,
    /// body run, optional early-break, iteration cap) is one
    /// state-graph node because `Aria.StateGraph` builds DAGs —
    /// representing the loop as a cycle of nodes wouldn't fit
    /// the underlying primitive. Body nodes were filtered out
    /// of the main emission pass; they're invoked here via the
    /// shared `executeBodyNode` static so the lowering stays
    /// consistent with non-loop emission.
    func addLoopNode(
        step: LoopStep,
        bodyNodes: [WorkflowNode],
        name: String,
        graph: inout StateGraph<WorkflowState>,
        callerPluginID: String,
        attended: Bool,
        sink: (any WorkflowEventSink)?
    ) {
        let context = BodyExecutionContext(
            broker: self.broker,
            llmProvider: self.llmProvider,
            jsEvaluator: self.jsEvaluator,
            pluginBroker: self.pluginToolBroker,
            serverLLMResolver: self.serverLLMResolver,
            mlxLLMResolver: self.mlxLLMResolver,
            mcpCredentialResolver: self.mcpCredentialResolver,
            callerPluginID: callerPluginID,
            attended: attended
        )
        let jsEvaluator = self.jsEvaluator
        graph.addNode(name, WorkflowCompiler.instrument(
            nodeID: step.id,
            outputBinding: nil,
            sink: sink
        ) { state in
            // swiftlint:disable:next closure_body_length
            var current = state
            var iteration = 0
            var exitedNaturally = false
            while iteration < step.maxIterations {
                if let key = step.iterationBinding {
                    current.bindings[key] = .integer(Int64(iteration))
                }
                let shouldContinue = try await jsEvaluator.evaluateBool(
                    expression: step.condition,
                    bindings: current.bindings
                )
                if !shouldContinue {
                    exitedNaturally = true
                    break
                }
                for body in bodyNodes {
                    // Emit per-body lifecycle events so the Run
                    // sheet sees body steps light up each
                    // iteration. Without these the body cards
                    // in the UI stay forever-pending — they
                    // look like they never ran even though the
                    // engine executes them — which is the bug
                    // users hit when they assume the body
                    // doesn't fire.
                    await sink?.emit(.stepStarted(nodeID: body.id))
                    do {
                        current = try await WorkflowCompiler.executeBodyNode(
                            body,
                            state: current,
                            context: context
                        )
                        let bodyBinding = WorkflowCompiler.bodyOutputBinding(body)
                        let bodyValue = bodyBinding.flatMap { current.bindings[$0] }
                        await sink?.emit(.stepCompleted(
                            nodeID: body.id,
                            outputBinding: bodyBinding,
                            value: bodyValue
                        ))
                    } catch {
                        await sink?.emit(.stepFailed(
                            nodeID: body.id,
                            error: error.localizedDescription
                        ))
                        throw error
                    }
                }
                iteration += 1
                if let breakExpr = step.breakOn {
                    let shouldBreak = try await jsEvaluator.evaluateBool(
                        expression: breakExpr,
                        bindings: current.bindings
                    )
                    if shouldBreak {
                        exitedNaturally = true
                        break
                    }
                }
            }
            if !exitedNaturally, iteration >= step.maxIterations {
                throw WorkflowEngineError.loopMaxIterationsExceeded
            }
            return current
        })
    }

    /// `outputBinding` of a body step, used by the loop's
    /// streaming-event wrapper to surface the latest value
    /// each iteration produced. Returns nil for variants that
    /// don't write a top-level binding (branch / parallel /
    /// nested loop / output — none of which are valid in a
    /// body anyway).
    static func bodyOutputBinding(_ node: WorkflowNode) -> String? {
        switch node {
        case let .llm(step): step.outputBinding
        case let .capability(step): step.outputBinding
        case let .pluginTool(step): step.outputBinding
        case let .mcpTool(step): step.outputBinding
        case let .transform(step): step.outputBinding
        case let .subAgent(step): step.outputBinding
        case .branch, .parallel, .loop, .output: nil
        }
    }

    /// Per-iteration body executor shared between the loop's
    /// inline runner and (future) any other place that needs to
    /// run a workflow node against a state without going through
    /// the state-graph machinery. Branch / parallel / nested loop
    /// / output aren't legal inside a loop body — the engine
    /// throws `loopBodyContainsUnsupportedNode` instead of
    /// silently misbehaving.
    // swiftlint:disable:next function_body_length
    static func executeBodyNode(
        _ node: WorkflowNode,
        state: WorkflowState,
        context: BodyExecutionContext
    ) async throws -> WorkflowState {
        switch node {
        case let .llm(step):
            let prompt = TemplateInterpolator.render(
                step.promptTemplate,
                bindings: state.bindings
            )
            let provider = await WorkflowCompiler.resolveLLMProvider(
                for: step,
                default: context.llmProvider,
                serverResolver: context.serverLLMResolver,
                mlxResolver: context.mlxLLMResolver
            )
            await WorkflowCompiler.bestEffortPrewarm(provider)
            let text = try await provider.generate(
                prompt: prompt,
                hint: step.modelHint,
                maxTokens: step.maxTokens
            )
            var next = state
            next.bindings[step.outputBinding] = .string(text)
            return next
        case let .capability(step):
            var resolved: [String: JSONValue] = [:]
            for (key, template) in step.argsTemplate {
                resolved[key] = .string(
                    TemplateInterpolator.render(template, bindings: state.bindings)
                )
            }
            let value = try await context.broker.call(
                capability: step.capability,
                method: step.method,
                arguments: resolved,
                callerPluginID: context.callerPluginID,
                attended: context.attended
            )
            var next = state
            next.bindings[step.outputBinding] = value
            return next
        case let .pluginTool(step):
            guard let pluginBroker = context.pluginBroker else {
                throw WorkflowEngineError.pluginToolBrokerUnavailable
            }
            var resolved: [String: JSONValue] = [:]
            for (key, template) in step.argsTemplate {
                resolved[key] = .string(
                    TemplateInterpolator.render(template, bindings: state.bindings)
                )
            }
            let value = try await pluginBroker.invoke(
                pluginID: step.pluginID,
                input: .object(resolved)
            )
            var next = state
            next.bindings[step.outputBinding] = value
            return next
        case let .mcpTool(step):
            let text = try await WorkflowCompiler.executeMCPTool(
                step: step,
                state: state,
                resolver: context.mcpCredentialResolver
            )
            var next = state
            next.bindings[step.outputBinding] = .string(text)
            return next
        case let .transform(step):
            let result = try await context.jsEvaluator.evaluate(
                expression: step.jsExpression,
                bindings: state.bindings
            )
            var next = state
            next.bindings[step.outputBinding] = result
            return next
        case .branch:
            throw WorkflowEngineError.loopBodyContainsUnsupportedNode("if/else")
        case .parallel:
            throw WorkflowEngineError.loopBodyContainsUnsupportedNode("parallel")
        case .loop:
            throw WorkflowEngineError.loopBodyContainsUnsupportedNode("nested loop")
        case .output:
            throw WorkflowEngineError.loopBodyContainsUnsupportedNode("output")
        case .subAgent:
            // SubAgent steps need the host's `SubAgentExecutor` —
            // they're top-level only, not legal inside a loop body
            // (matches branch/parallel/loop/output). Run a sub-agent
            // through its own top-level step instead.
            throw WorkflowEngineError.loopBodyContainsUnsupportedNode("sub-agent")
        }
    }

    // MARK: - BodyExecutionContext

    /// Bundle of injection seams + per-run flags that the loop
    /// body executor needs. Packaging them keeps
    /// `executeBodyNode` under the project's 6-param cap when
    /// the server-LLM resolver joins the broker / provider /
    /// evaluator / plugin-broker quartet.
    struct BodyExecutionContext {
        let broker: CapabilityBroker
        let llmProvider: any WorkflowLLMProvider
        let jsEvaluator: any WorkflowJSEvaluator
        let pluginBroker: (any PluginToolBroker)?
        let serverLLMResolver: ServerLLMProviderResolver?
        let mlxLLMResolver: MLXLLMProviderResolver?
        let mcpCredentialResolver: MCPCredentialResolver?
        let callerPluginID: String
        let attended: Bool
    }

    /// Branch passthrough: evaluate the predicate against the
    /// running bindings *before* the conditional edge runs, and
    /// stash the bool under a hidden binding the edge consults.
    /// This is the dance that lets us run async JS evaluation
    /// inside a synchronous `addConditionalEdge` route closure.
    func addBranchPredicateNode(
        branch: BranchStep,
        name: String,
        graph: inout StateGraph<WorkflowState>,
        sink: (any WorkflowEventSink)?
    ) {
        let evaluator = self.jsEvaluator
        let condition = branch.condition
        let bindingKey = WorkflowCompiler.branchResultBindingKey(branchID: branch.id)
        graph.addNode(name, WorkflowCompiler.instrument(
            nodeID: branch.id,
            outputBinding: bindingKey,
            sink: sink
        ) { state in
            let outcome = try await evaluator.evaluateBool(
                expression: condition,
                bindings: state.bindings
            )
            var next = state
            next.bindings[bindingKey] = .bool(outcome)
            return next
        })
    }
}

extension WorkflowCompiler {
    /// Emit a `SubAgentStep` as a single state-graph node that
    /// delegates to the configured `SubAgentExecutor`. Inputs are
    /// templated against the running bindings the same way every
    /// other step's `argsTemplate` resolves; the executor returns
    /// a `SubAgentResult` whose `asBinding` payload lands under
    /// the step's `outputBinding` (so downstream templates can
    /// address `{{step.text}}` and `{{step.structured.field}}`).
    func addSubAgentNode(
        step: SubAgentStep,
        name: String,
        graph: inout StateGraph<WorkflowState>,
        attended runAttended: Bool,
        sink: (any WorkflowEventSink)?
    ) {
        let executor = self.subAgentExecutor
        let classifier = self.retryClassifier
        graph.addNode(name, WorkflowCompiler.instrument(
            nodeID: step.id,
            outputBinding: step.outputBinding,
            sink: sink
        ) { state in
            guard let executor else {
                throw WorkflowEngineError.subAgentExecutorUnavailable
            }
            // Render every input template against the running
            // bindings before handing them to the executor — same
            // interpolation contract as `CapabilityStep.argsTemplate`.
            // Bound as `let` so the closure capture inside the
            // retry loop's `TaskGroup` body is Sendable-clean.
            let rendered: [String: JSONValue] = {
                var values: [String: JSONValue] = [:]
                for (slot, template) in step.inputBindings {
                    values[slot] = .string(
                        TemplateInterpolator.render(template, bindings: state.bindings)
                    )
                }
                return values
            }()
            let effectiveAttended = step.attended ?? runAttended

            // Wrap the single executor call in the same retry +
            // timeout helper LLM steps use, so SubAgent inherits
            // the policy story for free. Build a one-shot
            // "provider call" closure that just runs the executor;
            // the dispatch matrix in LLMStepExecutor isn't a fit
            // here (no multimodal / streaming / structured-output
            // axes) so we open-code the retry loop briefly.
            let attempts = step.retryPolicy?.maxAttempts ?? 1
            var lastError: any Error = WorkflowEngineError.underlying("no attempts ran")
            for attempt in 1...attempts {
                if let delay = step.retryPolicy?.delayBeforeAttempt(attempt) {
                    try await Task.sleep(for: delay)
                }
                do {
                    let result = try await Self.runWithOptionalTimeout(
                        stepID: step.id,
                        timeout: step.timeout
                    ) {
                        try await executor.run(
                            agentDefinitionID: step.agentDefinitionID,
                            inputs: rendered,
                            maxSteps: step.maxSteps,
                            attended: effectiveAttended
                        )
                    }
                    var next = state
                    next.bindings[step.outputBinding] = result.asBinding
                    return next
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    lastError = error
                    let category = classifier.classify(error)
                    let willRetry = attempt < attempts
                        && category.map { step.retryPolicy?.retryOn.contains($0) ?? false } ?? false
                    guard willRetry else {
                        throw error
                    }
                    let nextDelay = step.retryPolicy?.delayBeforeAttempt(attempt + 1)
                    await sink?.emit(.stepRetrying(
                        nodeID: step.id,
                        attempt: attempt,
                        nextDelay: nextDelay,
                        error: error.localizedDescription
                    ))
                }
            }
            throw lastError
        })
    }

    /// Small race helper shared by the SubAgent retry loop. Plain
    /// pass-through when no timeout is set; otherwise the same
    /// `TaskGroup` pattern `LLMStepExecutor` uses.
    static func runWithOptionalTimeout<T: Sendable>(
        stepID: UUID,
        timeout: Duration?,
        operation: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        guard let timeout else {
            return try await operation()
        }
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw WorkflowEngineError.stepTimedOut(stepID: stepID, after: timeout)
            }
            guard let value = try await group.next() else {
                throw WorkflowEngineError.underlying("subAgent task group produced no value")
            }
            group.cancelAll()
            return value
        }
    }
}
