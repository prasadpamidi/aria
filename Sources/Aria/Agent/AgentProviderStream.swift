import Foundation
import Tracing

// MARK: - ProviderStreamResponse

extension Agent {
    /// What the provider stream produced for a single step.
    struct ProviderStreamResponse {
        /// All the assistant text the provider streamed (excluding tool
        /// call arguments and tool results).
        let assistantText: String

        /// Tool calls the provider asked the agent to execute. The agent
        /// will dispatch each through its tool registry after the stream
        /// finishes.
        let toolCalls: [ToolCall]

        /// Tool calls the provider already executed itself (e.g.,
        /// FoundationModels resolves tools in-session). The agent records
        /// the result without re-executing.
        let preExecuted: [(call: ToolCall, result: ToolExecutionResult)]

        let finishReason: FinishReason
    }

    /// Pull events off the provider stream, translate them into agent
    /// events, and accumulate the resulting assistant text and tool
    /// calls.
    func streamProviderResponse(
        messages: [Message],
        executableTools: [AnyTool],
        continuation: AsyncThrowingStream<AgentEvent, any Error>.Continuation
    ) async throws -> ProviderStreamResponse {
        try await withSpan(AriaSemConv.Span.providerStream, ofKind: .client) { span in
            span.attributes[AriaSemConv.GenAI.system] =
                self.config.provider.capabilities.modelIdentifier
            span.attributes[AriaSemConv.GenAI.requestModel] =
                self.config.provider.capabilities.modelIdentifier
            return try await self.streamProviderResponseSpanned(
                messages: messages,
                executableTools: executableTools,
                continuation: continuation,
                span: span
            )
        }
    }

    private func streamProviderResponseSpanned(
        messages: [Message],
        executableTools: [AnyTool],
        continuation: AsyncThrowingStream<AgentEvent, any Error>.Continuation,
        span: Span
    ) async throws -> ProviderStreamResponse {
        var accumulator = ProviderStreamAccumulator()
        let stream = self.config.provider.stream(
            messages: messages,
            executableTools: executableTools,
            options: self.config.generationOptions
        )
        for try await event in stream {
            try Task.checkCancellation()
            self.process(event: event, accumulator: &accumulator, continuation: continuation, span: span)
        }
        span.attributes[AriaSemConv.GenAI.finishReasons] = [String(describing: accumulator.finishReason)]
        return ProviderStreamResponse(
            assistantText: accumulator.assistantText,
            toolCalls: accumulator.assembler.collected,
            preExecuted: accumulator.preExecuted,
            finishReason: accumulator.finishReason
        )
    }

    /// Translate one provider event into agent-side accumulator
    /// updates + emitted `AgentEvent`s + span/metric annotations.
    private func process(
        event: ProviderEvent,
        accumulator: inout ProviderStreamAccumulator,
        continuation: AsyncThrowingStream<AgentEvent, any Error>.Continuation,
        span: Span
    ) {
        switch event {
        case .messageStart:
            return
        case let .usage(usage):
            // Surface OTel GenAI semconv attributes + metrics so
            // downstream backends auto-render token usage.
            span.attributes[AriaSemConv.GenAI.inputTokens] = Int64(usage.inputTokens)
            span.attributes[AriaSemConv.GenAI.outputTokens] = Int64(usage.outputTokens)
            let system = self.config.provider.capabilities.modelIdentifier
            AriaMetrics.tokenUsage(system: system, type: "input").record(usage.inputTokens)
            AriaMetrics.tokenUsage(system: system, type: "output").record(usage.outputTokens)
        case let .textDelta(chunk):
            accumulator.assistantText += chunk
            continuation.yield(.textDelta(chunk))
        case let .toolCallStart(call):
            accumulator.assembler.start(call: call)
        case let .toolCallDelta(id, delta):
            accumulator.assembler.appendDelta(id: id, delta: delta)
        case let .toolCallEnd(id):
            if let finalized = accumulator.assembler.end(id: id) {
                continuation.yield(.toolCallRequested(finalized))
            }
        case let .toolCallExecuted(call, result):
            accumulator.preExecuted.append((call, result))
            continuation.yield(.toolCallRequested(call))
            continuation.yield(.toolExecutionStart(callId: call.id))
            continuation.yield(.toolExecutionEnd(callId: call.id, result: result))
        case let .messageStop(reason):
            accumulator.finishReason = reason
        }
    }
}

// MARK: - ProviderStreamAccumulator

/// Mutable state collected as the provider stream is iterated. Pulled
/// out so `streamProviderResponseSpanned` can split the loop body
/// without juggling four independent locals.
private struct ProviderStreamAccumulator {
    var assembler = ToolCallAssembler()
    var preExecuted: [(call: ToolCall, result: ToolExecutionResult)] = []
    var assistantText: String = ""
    var finishReason: FinishReason = .endTurn
}

// MARK: - ToolCallAssembler

/// Collects `toolCallStart` / `toolCallDelta` / `toolCallEnd` event
/// streams into final `ToolCall`s.
///
/// Some providers emit a single `toolCallStart` with full arguments;
/// others stream JSON arguments incrementally. The assembler handles
/// both — `start` records the call, deltas accumulate as a string buffer,
/// and `end` parses the buffer (when present) to produce the final args.
private struct ToolCallAssembler {
    // MARK: Internal

    private(set) var collected: [ToolCall] = []

    mutating func start(call: ToolCall) {
        if self.pending[call.id] == nil {
            self.order.append(call.id)
        }
        self.pending[call.id] = call
        self.buffers[call.id] = ""
    }

    mutating func appendDelta(id: String, delta: String) {
        self.buffers[id, default: ""] += delta
    }

    mutating func end(id: String) -> ToolCall? {
        guard let call = pending[id] else {
            return nil
        }
        let buffer = self.buffers[id] ?? ""
        let finalCall = self.finalize(call: call, buffer: buffer)
        self.collected.append(finalCall)
        self.pending.removeValue(forKey: id)
        self.buffers.removeValue(forKey: id)
        return finalCall
    }

    // MARK: Private

    private var pending: [String: ToolCall] = [:]
    private var buffers: [String: String] = [:]
    private var order: [String] = []

    private func finalize(call: ToolCall, buffer: String) -> ToolCall {
        guard !buffer.isEmpty else {
            return call
        }
        guard let data = buffer.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return call
        }
        return ToolCall(id: call.id, name: call.name, arguments: parsed)
    }
}
