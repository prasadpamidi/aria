import Foundation

// MARK: - ProviderStreamResponse

extension Agent {
    /// What the provider stream produced for a single step.
    struct ProviderStreamResponse {
        let assistantText: String
        let toolCalls: [ToolCall]
        let finishReason: FinishReason
    }

    /// Pull events off the provider stream, translate them into agent
    /// events, and accumulate the resulting assistant text and tool
    /// calls.
    func streamProviderResponse(
        messages: [Message],
        tools: [ToolDefinition],
        continuation: AsyncThrowingStream<AgentEvent, any Error>.Continuation
    ) async throws -> ProviderStreamResponse {
        var assembler = ToolCallAssembler()
        var assistantText = ""
        var finishReason: FinishReason = .endTurn

        let stream = self.config.provider.stream(
            messages: messages,
            tools: tools,
            options: self.config.generationOptions
        )

        for try await event in stream {
            try Task.checkCancellation()
            switch event {
            case .messageStart:
                continue
            case let .textDelta(chunk):
                assistantText += chunk
                continuation.yield(.textDelta(chunk))
            case let .toolCallStart(call):
                assembler.start(call: call)
            case let .toolCallDelta(id, delta):
                assembler.appendDelta(id: id, delta: delta)
            case let .toolCallEnd(id):
                if let finalized = assembler.end(id: id) {
                    continuation.yield(.toolCallRequested(finalized))
                }
            case let .messageStop(reason):
                finishReason = reason
            case .usage:
                continue
            }
        }

        return ProviderStreamResponse(
            assistantText: assistantText,
            toolCalls: assembler.collected,
            finishReason: finishReason
        )
    }
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
