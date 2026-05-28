import Aria
import Foundation

// MARK: - LLMStepExecutor

/// Runs one `LLMStep` end-to-end: prompt assembly, multimodal
/// dispatch, structured/text routing, optional streaming, retry +
/// timeout. Pulled out of `WorkflowCompiler+Nodes` so the dispatch
/// matrix has one home and per-attempt classification stays out of
/// the graph wiring.
///
/// All work happens inside `execute(state:sink:)`. The compiler
/// constructs the executor at graph-emission time with everything
/// resolved (provider, prompt, skill IDs); the executor handles
/// per-attempt retry, timing, and event emission against the
/// optional `WorkflowEventSink`.
enum LLMStepExecutor {
    // MARK: Internal

    /// Resolved per-step configuration. Built once at graph-emit
    /// time so the per-run hot path doesn't re-resolve providers /
    /// skills / classifiers.
    struct Plan {
        let stepID: UUID
        let outputBinding: String
        let promptTemplate: String
        let modelHint: ModelFamilyHint
        let maxTokens: Int?
        let structuredOutputSchema: String?
        let attachmentBindings: [String]
        let requiredModalities: Set<ContentModality>
        let retryPolicy: RetryPolicy?
        let timeout: Duration?
        let allowStreaming: Bool
    }

    /// Dispatch + execute one attempt. `bindings` is the running
    /// state at execution time; resolved attachments come from
    /// looking up `attachmentBindings` against it.
    static func execute(
        plan: Plan,
        prompt: String,
        bindings: [String: JSONValue],
        provider: any WorkflowLLMProvider,
        classifier: any WorkflowRetryClassifier,
        sink: (any WorkflowEventSink)?
    ) async throws -> JSONValue {
        let attempts = plan.retryPolicy?.maxAttempts ?? 1
        var lastError: any Error = WorkflowEngineError.underlying("no attempts ran")

        for attempt in 1...attempts {
            if let delay = plan.retryPolicy?.delayBeforeAttempt(attempt) {
                try await Task.sleep(for: delay)
            }
            do {
                return try await Self.runOneAttempt(
                    plan: plan,
                    prompt: prompt,
                    bindings: bindings,
                    provider: provider,
                    sink: sink
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                let category = classifier.classify(error)
                let willRetry = attempt < attempts
                    && category.map { plan.retryPolicy?.retryOn.contains($0) ?? false } ?? false
                guard willRetry else {
                    throw error
                }
                let nextDelay = plan.retryPolicy?.delayBeforeAttempt(attempt + 1)
                await sink?.emit(.stepRetrying(
                    nodeID: plan.stepID,
                    attempt: attempt,
                    nextDelay: nextDelay,
                    error: error.localizedDescription
                ))
            }
        }
        throw lastError
    }

    // MARK: Private

    // MARK: - Per-attempt dispatch

    private static func runOneAttempt(
        plan: Plan,
        prompt: String,
        bindings: [String: JSONValue],
        provider: any WorkflowLLMProvider,
        sink: (any WorkflowEventSink)?
    ) async throws -> JSONValue {
        // Honour per-attempt timeout via a race. Cancellation of
        // the losing task propagates because `withThrowingTaskGroup`
        // cancels surviving children on group exit.
        if let timeout = plan.timeout {
            return try await withThrowingTaskGroup(of: JSONValue.self) { group in
                group.addTask {
                    try await Self.dispatch(
                        plan: plan,
                        prompt: prompt,
                        bindings: bindings,
                        provider: provider,
                        sink: sink
                    )
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw WorkflowEngineError.stepTimedOut(stepID: plan.stepID, after: timeout)
                }
                guard let value = try await group.next() else {
                    throw WorkflowEngineError.underlying("step task group produced no value")
                }
                group.cancelAll()
                return value
            }
        }
        return try await Self.dispatch(
            plan: plan,
            prompt: prompt,
            bindings: bindings,
            provider: provider,
            sink: sink
        )
    }

    private static func dispatch(
        plan: Plan,
        prompt: String,
        bindings: [String: JSONValue],
        provider: any WorkflowLLMProvider,
        sink: (any WorkflowEventSink)?
    ) async throws -> JSONValue {
        // Multimodal trumps text-only paths — if the step declares
        // attachment bindings, every dispatch goes through
        // generateMultimodal so we don't have to maintain parallel
        // text + multimodal codepaths.
        if !plan.attachmentBindings.isEmpty {
            let blocks = try Self.resolveAttachmentBlocks(
                plan: plan,
                prompt: prompt,
                bindings: bindings
            )
            return try await provider.generateMultimodal(
                content: blocks,
                hint: plan.modelHint,
                maxTokens: plan.maxTokens,
                schemaID: plan.structuredOutputSchema
            )
        }

        // Structured-output streaming path: opted into by both the
        // caller (sink present → runStreaming) AND the provider
        // (capabilities.supportsStreamingStructured). Yields per-
        // snapshot `.stepPartial` events; the final yield is also
        // returned as the binding value. Plan.allowStreaming reflects
        // both conditions resolved at compile time.
        if let schemaID = plan.structuredOutputSchema,
           !schemaID.isEmpty,
           plan.allowStreaming,
           let sink {
            var latest: JSONValue?
            let stream = provider.streamStructured(
                prompt: prompt,
                hint: plan.modelHint,
                maxTokens: plan.maxTokens,
                schemaID: schemaID
            )
            for try await snapshot in stream {
                latest = snapshot
                await sink.emit(.stepPartial(
                    nodeID: plan.stepID,
                    outputBinding: plan.outputBinding,
                    snapshot: snapshot
                ))
            }
            guard let final = latest else {
                throw WorkflowEngineError.underlying(
                    "streaming structured output produced no snapshots"
                )
            }
            return final
        }

        // Non-streaming structured path.
        if let schemaID = plan.structuredOutputSchema, !schemaID.isEmpty {
            return try await provider.generateStructured(
                prompt: prompt,
                hint: plan.modelHint,
                maxTokens: plan.maxTokens,
                schemaID: schemaID
            )
        }

        // Plain text.
        let text = try await provider.generate(
            prompt: prompt,
            hint: plan.modelHint,
            maxTokens: plan.maxTokens
        )
        return .string(text)
    }

    private static func resolveAttachmentBlocks(
        plan: Plan,
        prompt: String,
        bindings: [String: JSONValue]
    ) throws -> [ContentBlock] {
        // Always prefix with the rendered prompt as a text block —
        // the prompt is still the "instruction" portion of a
        // multimodal call. Attachments are appended in declaration
        // order so providers see them in the same sequence the
        // workflow author declared.
        var blocks: [ContentBlock] = [.text(prompt)]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for path in plan.attachmentBindings {
            guard let value = Self.lookup(path: path, in: bindings) else {
                throw WorkflowEngineError.multimodalAttachmentInvalid(
                    binding: path,
                    reason: "binding not present in workflow state"
                )
            }
            // The binding is `JSONValue` shaped — re-encode + decode
            // through `ContentBlock`. Supports both single-block and
            // array-of-blocks bindings.
            do {
                let data = try encoder.encode(value)
                if let single = try? decoder.decode(ContentBlock.self, from: data) {
                    blocks.append(single)
                    continue
                }
                let array = try decoder.decode([ContentBlock].self, from: data)
                blocks.append(contentsOf: array)
            } catch {
                throw WorkflowEngineError.multimodalAttachmentInvalid(
                    binding: path,
                    reason: error.localizedDescription
                )
            }
        }
        return blocks
    }

    /// Resolve a dotted path (`input.photo`, `photo`, `foo.bar.baz`)
    /// against the workflow bindings map. Matches the addressing
    /// convention `TemplateInterpolator` uses for `{{name.field}}`
    /// — workflow inputs live under `input.<name>` after the
    /// runner wraps them, so the same path that templates use
    /// works here. A bare `"photo"` first checks `bindings["photo"]`
    /// and then falls back to `bindings["input"]["photo"]` so the
    /// common case of "the input value is my attachment" doesn't
    /// require authors to spell out the `input.` prefix.
    private static func lookup(path: String, in bindings: [String: JSONValue]) -> JSONValue? {
        let components = path.split(separator: ".").map(String.init)
        if components.isEmpty {
            return nil
        }
        // Direct dotted-path walk first.
        if let value = Self.walk(components: components, in: bindings) {
            return value
        }
        // Convenience: bare key falls back to `input.<key>`.
        if components.count == 1,
           case let .object(inputDict)? = bindings["input"],
           let value = inputDict[components[0]] {
            return value
        }
        return nil
    }

    private static func walk(components: [String], in bindings: [String: JSONValue]) -> JSONValue? {
        var current: JSONValue = .object(bindings)
        for component in components {
            guard case let .object(dict) = current,
                  let next = dict[component] else {
                return nil
            }
            current = next
        }
        return current
    }
}
