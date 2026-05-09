import Foundation

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
        guard let tool = config.tool(named: call.name) else {
            throw AgentError.toolNotFound(call.name)
        }

        continuation.yield(.toolExecutionStart(callId: call.id))

        let context = ToolContext(runId: UUID())
        let started = ContinuousClock.now
        let result: ToolExecutionResult

        do {
            let output = try await Self.runWithTimeout(
                timeout: self.config.toolTimeout,
                operation: { try await tool.invoke(call.arguments, context) }
            )
            let duration = ContinuousClock.now - started
            result = ToolExecutionResult(
                output: output,
                isError: false,
                duration: duration
            )
        } catch let error as AgentError {
            let duration = ContinuousClock.now - started
            result = ToolExecutionResult(
                output: .object(["error": .string(String(describing: error))]),
                isError: true,
                duration: duration
            )
        } catch {
            let duration = ContinuousClock.now - started
            result = ToolExecutionResult(
                output: .object(["error": .string(String(describing: error))]),
                isError: true,
                duration: duration
            )
        }

        continuation.yield(.toolExecutionEnd(callId: call.id, result: result))

        let resultText = Self.renderToolResult(result)
        return Message.tool(callId: call.id, text: resultText)
    }

    private static func renderToolResult(_ result: ToolExecutionResult) -> String {
        guard let data = try? result.output.canonicalData(),
              let string = String(data: data, encoding: .utf8) else {
            return result.isError ? "(tool error)" : "(tool output)"
        }
        return string
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
