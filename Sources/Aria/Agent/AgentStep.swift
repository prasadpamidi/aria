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
    /// provider, accumulate tool calls, execute tools the agent owns,
    /// and record any tools the provider already executed.
    func runStep(
        state: AgentState,
        continuation: AsyncThrowingStream<AgentEvent, any Error>.Continuation
    ) async throws -> StepOutcome {
        var workingState = state
        let messagesForProvider = self.buildProviderMessages(state: workingState)

        continuation.yield(.assistantStart)

        let response = try await self.streamProviderResponse(
            messages: messagesForProvider,
            executableTools: self.config.tools,
            continuation: continuation
        )

        let allToolCalls = response.toolCalls + response.preExecuted.map(\.call)
        let assistantMessage = Message.assistant(
            response.assistantText,
            toolCalls: allToolCalls
        )
        workingState.messages.append(assistantMessage)

        for entry in response.preExecuted {
            workingState.messages.append(
                .tool(callId: entry.call.id, text: Self.renderResult(entry.result))
            )
        }

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

    /// Render a `ToolExecutionResult` back into a string suitable for
    /// embedding in a `tool` message's content.
    static func renderResult(_ result: ToolExecutionResult) -> String {
        guard let data = try? result.output.canonicalData(),
              let string = String(data: data, encoding: .utf8) else {
            return result.isError ? "(tool error)" : "(tool output)"
        }
        return string
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
