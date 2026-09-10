import Foundation
import Tracing

// MARK: - Tool execution

extension Agent {
    /// Execute tool calls and return the resulting `tool` messages.
    ///
    /// Honors `AgentConfig.parallelToolCalls`: parallel execution uses a
    /// `ThrowingTaskGroup` and preserves call order in the returned
    /// messages. Each tool execution is wrapped in a per-tool timeout
    /// derived from `AgentConfig.toolTimeout`.
    func executeToolCalls(
        _ calls: [ToolCall],
        continuation: AsyncThrowingStream<AgentEvent, any Error>.Continuation
    ) async throws -> [Message] {
        guard !calls.isEmpty else {
            return []
        }

        let parallel = self.config.parallelToolCalls
            && self.config.provider.capabilities.supportsParallelToolCalls

        if parallel, calls.count > 1 {
            return try await self.runToolsInParallel(calls, continuation: continuation)
        }
        return try await self.runToolsSequentially(calls, continuation: continuation)
    }

    private func runToolsSequentially(
        _ calls: [ToolCall],
        continuation: AsyncThrowingStream<AgentEvent, any Error>.Continuation
    ) async throws -> [Message] {
        var messages: [Message] = []
        for call in calls {
            try Task.checkCancellation()
            let message = try await self.executeOne(call: call, continuation: continuation)
            messages.append(message)
        }
        return messages
    }

    private func runToolsInParallel(
        _ calls: [ToolCall],
        continuation: AsyncThrowingStream<AgentEvent, any Error>.Continuation
    ) async throws -> [Message] {
        try await withThrowingTaskGroup(of: (Int, Message).self) { group in
            for (index, call) in calls.enumerated() {
                group.addTask {
                    let message = try await self.executeOne(call: call, continuation: continuation)
                    return (index, message)
                }
            }
            var indexed: [(Int, Message)] = []
            for try await pair in group {
                indexed.append(pair)
            }
            indexed.sort { $0.0 < $1.0 }
            return indexed.map(\.1)
        }
    }

    private func executeOne(
        call: ToolCall,
        continuation: AsyncThrowingStream<AgentEvent, any Error>.Continuation
    ) async throws -> Message {
        try await withSpan(AriaSemConv.Span.toolExecute, ofKind: .internal) { span in
            span.attributes[AriaSemConv.GenAI.toolName] = call.name
            span.attributes[AriaSemConv.GenAI.toolCallId] = call.id
            return try await self.executeOneSpanned(
                call: call,
                continuation: continuation,
                span: span
            )
        }
    }

    private func executeOneSpanned(
        call: ToolCall,
        continuation: AsyncThrowingStream<AgentEvent, any Error>.Continuation,
        span: Span
    ) async throws -> Message {
        guard let tool = config.tool(named: call.name) else {
            throw AgentError.toolNotFound(call.name)
        }

        continuation.yield(.toolExecutionStart(callId: call.id))
        let result = await self.invokeTool(tool: tool, call: call)
        continuation.yield(.toolExecutionEnd(callId: call.id, result: result))

        AriaMetrics.toolExecutionsTotal(name: call.name, isError: result.isError).increment()
        AriaMetrics.toolDuration(name: call.name)
            .record(Self.seconds(in: result.duration))
        if result.isError {
            span.setStatus(SpanStatus(code: .error))
        }
        return Message.tool(callId: call.id, text: Self.renderToolResult(result))
    }

    /// Invoke `tool.invoke` under the configured timeout and turn any
    /// thrown error into an `isError: true` `ToolExecutionResult`.
    private func invokeTool(
        tool: AnyTool,
        call: ToolCall
    ) async -> ToolExecutionResult {
        let context = ToolContext(runId: UUID())
        let started = ContinuousClock.now
        // Reconcile the model's arguments with the schema it was given.
        //
        // Small models quote their numbers. A 0.8B model called a
        // weather tool with `{"days": "1", "latitude": "56.35"}` and
        // the server refused it — right tool, right intent, right
        // values, defeated by quotation marks. The schema says what
        // each field is, so this is fixable here rather than by asking
        // the model to try again.
        let arguments = ToolArgumentCoercion.coerce(
            call.arguments,
            to: tool.definition.inputSchema
        )
        do {
            let output = try await Self.runWithTimeout(
                timeout: self.config.toolTimeout,
                operation: { try await tool.invoke(arguments, context) }
            )
            return ToolExecutionResult(
                output: output,
                isError: false,
                duration: ContinuousClock.now - started
            )
        } catch {
            return ToolExecutionResult(
                output: .object(["error": .string(String(describing: error))]),
                isError: true,
                duration: ContinuousClock.now - started
            )
        }
    }

    /// Convert a `Duration` to a `Double` second count for metrics
    /// recording. `Duration.components` returns `(seconds, attoseconds)`.
    private static func seconds(in duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) * 1e-18
    }

    /// A failed result carries `ToolFailure.guidance` with it, so the
    /// model reads what a failure means at the moment it reads the
    /// failure. See `ToolFailure`.
    private static func renderToolResult(_ result: ToolExecutionResult) -> String {
        ToolFailure.render(result)
    }

    /// Run an operation with a deadline; throws `AgentError.timeout` if
    /// the deadline passes.
    private static func runWithTimeout<T: Sendable>(
        timeout: Duration,
        operation: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw AgentError.timeout(timeout)
            }
            guard let result = try await group.next() else {
                throw AgentError.timeout(timeout)
            }
            group.cancelAll()
            return result
        }
    }
}
