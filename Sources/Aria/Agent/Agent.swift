import Foundation
import Logging
import Tracing

// MARK: - Agent

/// Aria's tool-calling agent.
///
/// `Agent` orchestrates an `LLMProvider` and a set of `AnyTool`s in a
/// streaming control loop. Each invocation produces an isolated
/// `AgentState` — the agent itself holds no mutable state, so it is a
/// `Sendable` value and can be reused across calls and tasks freely.
///
/// Concurrency:
/// - All work runs inside a single `Task` per `stream` call.
/// - Cancelling the consumer's iteration cancels the underlying task.
/// - Tool execution honors `Task.isCancelled` and the per-tool timeout
///   from `AgentConfig`.
public struct Agent: Sendable {
    // MARK: Lifecycle

    public init(config: AgentConfig) {
        self.config = config
    }

    // MARK: Public

    /// Read access to the agent's static configuration. Public so
    /// out-of-module extensions (e.g., `AriaApple`'s
    /// `respond(_:as:)`) can resolve the provider; the loop helpers in
    /// sibling files in this module also rely on it.
    public let config: AgentConfig

    /// Stream the agent's events for the given input.
    ///
    /// The returned stream emits `AgentEvent`s as they happen. The stream
    /// finishes when the agent reaches a terminal state (model ended its
    /// turn naturally, max steps reached, an error occurred, or the
    /// consumer cancelled).
    public func stream(
        _ input: AgentInput,
        options: RunOptions = RunOptions()
    ) -> AsyncThrowingStream<AgentEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await withSpan(AriaSemConv.Span.agentRun, ofKind: .internal) { span in
                    span.attributes[AriaSemConv.GenAI.system] =
                        self.config.provider.capabilities.modelIdentifier
                    span.attributes[AriaSemConv.GenAI.requestModel] =
                        self.config.provider.capabilities.modelIdentifier
                    span.attributes[AriaSemConv.GenAI.operationName] = "chat"
                    if let threadId = self.config.threadId {
                        span.attributes[AriaSemConv.Aria.threadId] = threadId
                    }
                    await self.runLoopHandlingErrors(
                        input: input,
                        options: options,
                        continuation: continuation
                    )
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Private

    private static let logger = Logger(label: "com.aria.agent")

    private static func validateConfig(_ config: AgentConfig) throws {
        if !config.tools.isEmpty, !config.provider.capabilities.supportsToolUse {
            throw AgentError.configurationInvalid(
                "Provider \(config.provider.capabilities.modelIdentifier) does not support "
                    + "tool use, but \(config.tools.count) tool(s) were configured"
            )
        }
        if config.maxSteps <= 0 {
            throw AgentError.configurationInvalid("maxSteps must be > 0")
        }
    }

    /// Wraps `runLoop` in the agent's error envelope: surface a typed
    /// `AgentError`, finish the stream, and emit a final `.error` event
    /// so consumers see the same value as the throw.
    private func runLoopHandlingErrors(
        input: AgentInput,
        options: RunOptions,
        continuation: AsyncThrowingStream<AgentEvent, any Error>.Continuation
    ) async {
        do {
            try await self.runLoop(
                input: input,
                options: options,
                continuation: continuation
            )
        } catch is CancellationError {
            continuation.yield(.error(.cancelled))
            continuation.finish(throwing: AgentError.cancelled)
        } catch let error as AgentError {
            continuation.yield(.error(error))
            continuation.finish(throwing: error)
        } catch {
            let wrapped = AgentError.providerFailed(
                "Agent loop failed",
                underlying: ErrorBox(error)
            )
            continuation.yield(.error(wrapped))
            continuation.finish(throwing: wrapped)
        }
    }

    private func runLoop(
        input: AgentInput,
        options: RunOptions,
        continuation: AsyncThrowingStream<AgentEvent, any Error>.Continuation
    ) async throws {
        try Self.validateConfig(self.config)

        var state = self.makeInitialState(input: input, continuation: continuation)
        state = try await self.applyMiddleware(state) { middleware, current in
            try await middleware.beforeRun(current)
        }

        for stepIndex in 0..<self.config.maxSteps {
            try options.checkpoint()
            continuation.yield(.stepStart(stepIndex))
            let (newState, outcome) = try await self.runOneStep(
                stepIndex: stepIndex,
                state: state,
                continuation: continuation
            )
            state = newState
            AriaMetrics.agentStepsTotal.increment()
            continuation.yield(.stepEnd(stepIndex))
            state.stepCount += 1

            if outcome.isTerminal {
                try await self.finalize(
                    state: &state,
                    finishReason: outcome.finishReason,
                    continuation: continuation
                )
                return
            }
        }

        try await self.finalize(
            state: &state,
            finishReason: .maxStepsReached,
            continuation: continuation
        )
    }

    /// Run one step inside a `agent.step` span: apply beforeStep, run
    /// the provider/tool round, apply afterStep. Returns the new state
    /// and the step's outcome.
    private func runOneStep(
        stepIndex: Int,
        state: AgentState,
        continuation: AsyncThrowingStream<AgentEvent, any Error>.Continuation
    ) async throws -> (AgentState, StepOutcome) {
        try await withSpan(AriaSemConv.Span.agentStep, ofKind: .internal) { span in
            span.attributes[AriaSemConv.Aria.stepIndex] = stepIndex
            var localState = try await self.applyMiddleware(state) { mw, current in
                try await mw.beforeStep(current)
            }
            let outcome = try await self.runStep(
                state: localState,
                continuation: continuation
            )
            localState = outcome.state
            localState = try await self.applyMiddleware(localState) { mw, current in
                try await mw.afterStep(current)
            }
            return (localState, outcome)
        }
    }

    /// Apply afterRun middleware and finish the stream with the
    /// terminal `AgentEvent.finish(reason)`. Mutates `state` so the
    /// caller can return early after invoking.
    private func finalize(
        state: inout AgentState,
        finishReason: FinishReason,
        continuation: AsyncThrowingStream<AgentEvent, any Error>.Continuation
    ) async throws {
        let finalEvent = AgentEvent.finish(finishReason)
        state = try await self.applyMiddleware(state) { mw, current in
            try await mw.afterRun(current, finalEvent: finalEvent)
        }
        state.lastFinishReason = finishReason
        continuation.yield(finalEvent)
        continuation.finish()
    }

    private func makeInitialState(
        input: AgentInput,
        continuation: AsyncThrowingStream<AgentEvent, any Error>.Continuation
    ) -> AgentState {
        let threadId = self.config.threadId ?? UUID().uuidString
        var messages: [Message] = []
        for message in input.messages {
            messages.append(message)
            continuation.yield(.userMessageReceived(message))
        }
        return AgentState(threadId: threadId, messages: messages)
    }

    private func applyMiddleware(
        _ state: AgentState,
        block: (any AgentMiddleware, AgentState) async throws -> AgentState
    ) async throws -> AgentState {
        var current = state
        for middleware in self.config.middleware {
            current = try await block(middleware, current)
        }
        return current
    }
}
