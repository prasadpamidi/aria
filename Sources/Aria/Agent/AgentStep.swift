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
        let assembled = await self.assembleContext(state: workingState)

        continuation.yield(.assistantStart)

        let response = try await self.streamProviderResponse(
            messages: assembled.messages,
            executableTools: assembled.tools,
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

    /// Build the request for this step.
    ///
    /// This is the only point in the loop where the system prompt, the
    /// tool set, and the message history are all in scope — which is
    /// why context budgeting belongs here rather than in middleware.
    /// Middleware runs strictly earlier, before the system prompt is
    /// prepended, and tool definitions never pass through `AgentState`
    /// at all.
    ///
    /// With no assembler configured the behaviour is unchanged from
    /// before this hook existed: prompt prepended, every tool sent.
    private func assembleContext(state: AgentState) async -> AssembledContext {
        guard let assembler = config.contextAssembler else {
            return AssembledContext(
                messages: self.buildProviderMessages(state: state),
                tools: self.config.tools,
                allocation: ContextAllocation()
            )
        }

        let budget = self.config.contextBudget ?? Self.derivedBudget(
            from: self.config.provider.capabilities
        )
        return await assembler.assemble(
            systemPrompt: self.config.systemPrompt,
            tools: self.config.tools,
            state: state,
            budget: budget
        )
    }

    /// Fall back to the provider's own reported window when the caller
    /// didn't supply a budget.
    ///
    /// `effectiveContextTokens` prefers the usable figure over the
    /// advertised one, which matters on-device where the two can differ
    /// by more than an order of magnitude. When the provider reports
    /// nothing, pick a conservative window rather than an unbounded
    /// one — silently sending an unbounded request is the failure this
    /// whole mechanism exists to prevent.
    private static func derivedBudget(from capabilities: ProviderCapabilities) -> ContextBudget {
        ContextBudget(total: capabilities.effectiveContextTokens ?? 8192)
    }
}
