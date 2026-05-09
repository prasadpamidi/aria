import Foundation

// MARK: - StepOutcome

extension Agent {
    /// What a single step produced. Threaded back to `runLoop` to drive
    /// the outer iteration.
    struct StepOutcome {
        let state: AgentState
        let finishReason: FinishReason
        /// `true` if this step ended the run (no tool calls or model
        /// signalled it was done).
        let isTerminal: Bool
    }

    /// Run one step of the agent loop: assemble messages, call the
    /// provider, accumulate tool calls, execute tools.
    func runStep(
        state: AgentState,
        continuation: AsyncThrowingStream<AgentEvent, any Error>.Continuation
    ) async throws -> StepOutcome {
        var workingState = state
        let messagesForProvider = self.buildProviderMessages(state: workingState)
        let toolDefinitions = self.config.tools.map(\.definition)

        continuation.yield(.assistantStart)

        let response = try await self.streamProviderResponse(
            messages: messagesForProvider,
            tools: toolDefinitions,
            continuation: continuation
        )

        let assistantMessage = Message.assistant(
            response.assistantText,
            toolCalls: response.toolCalls
        )
        workingState.messages.append(assistantMessage)

        let modelWantsTools = !response.toolCalls.isEmpty
            && response.finishReason == .toolUse
        if !modelWantsTools {
            return StepOutcome(
                state: workingState,
                finishReason: response.finishReason,
                isTerminal: true
            )
        }

        let toolMessages = try await self.executeToolCalls(
            response.toolCalls,
            continuation: continuation
        )
        workingState.messages.append(contentsOf: toolMessages)

        return StepOutcome(
            state: workingState,
            finishReason: response.finishReason,
            isTerminal: false
        )
    }

    private func buildProviderMessages(state: AgentState) -> [Message] {
        var result: [Message] = []
        if let systemPrompt = config.systemPrompt, !systemPrompt.isEmpty {
            result.append(.system(systemPrompt))
        }
        result.append(contentsOf: state.messages)
        return result
    }
}
