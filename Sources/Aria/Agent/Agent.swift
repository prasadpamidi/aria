import Foundation
import Logging

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
                await self.runLoopHandlingErrors(
                    input: input,
                    options: options,
                    continuation: continuation
                )
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Internal

    /// Internal so loop helpers in sibling files (`AgentStep.swift`,
    /// `AgentProviderStream.swift`, `AgentToolExecution.swift`) can read
    /// it. Swift's `private` is file-scoped, not type-scoped.
    let config: AgentConfig

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

            state = try await self.applyMiddleware(state) { middleware, current in
                try await middleware.beforeStep(current)
            }

            let outcome = try await self.runStep(
                state: state,
                continuation: continuation
            )
            state = outcome.state

            state = try await self.applyMiddleware(state) { middleware, current in
                try await middleware.afterStep(current)
            }
            continuation.yield(.stepEnd(stepIndex))
            state.stepCount += 1

            if outcome.isTerminal {
                let finalEvent = AgentEvent.finish(outcome.finishReason)
                state = try await self.applyMiddleware(state) { middleware, current in
                    try await middleware.afterRun(current, finalEvent: finalEvent)
                }
                state.lastFinishReason = outcome.finishReason
                continuation.yield(finalEvent)
                continuation.finish()
                return
            }
        }

        let finalEvent = AgentEvent.finish(.maxStepsReached)
        state = try await self.applyMiddleware(state) { middleware, current in
            try await middleware.afterRun(current, finalEvent: finalEvent)
        }
        state.lastFinishReason = .maxStepsReached
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
