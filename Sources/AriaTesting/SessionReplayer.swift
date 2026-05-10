import Aria
import Foundation

// MARK: - SessionReplayer

/// Helpers for replaying a recorded `SessionBundle`.
///
/// Lives in `AriaTesting` because replay is a testing / inspection
/// concern — the production path is the live agent. Two things you
/// can do with a recorded bundle:
///
/// 1. **Re-execute against a mock provider.** Build a
///    `MockLLMProvider` from the agent record so a fresh `Agent`
///    sees the exact same stream events the original run did. Useful
///    for regression tests, prompt experiments where you want
///    deterministic LLM output, and comparing different middleware
///    configurations against an identical model trajectory.
///
/// 2. **Decode graph states back to typed values.** State payloads
///    in `StateGraphRecord` are stored as JSON-encoded `Data`;
///    `states(from:as:)` walks them and returns typed input + output
///    pairs in node order so a test can assert specific transitions
///    happened.
public enum SessionReplayer {
    // MARK: Public

    // MARK: - Provider replay

    /// Build a `MockLLMProvider` whose stream events reproduce the
    /// recorded agent run. Each `AgentStepRecord` becomes one scene
    /// derived from the messages added between `messagesBefore` and
    /// `messagesAfter`:
    ///
    /// - assistant text → one `.textDelta`
    /// - assistant `toolCalls` → `.toolCallStart` + `.toolCallEnd`
    ///   pairs, which makes the replay agent dispatch its own tool
    ///   registry. The replay agent is expected to register a tool
    ///   with the same name; for deterministic tools the result will
    ///   match the recording. (V1 limitation: non-deterministic
    ///   tools may diverge — use a follow-up "replay tool registry"
    ///   to pin recorded results in that case.)
    /// - finish reason → `.toolUse` when a tool fired,
    ///   `.endTurn` otherwise, so the agent loop advances or stops
    ///   the same way the original run did
    public static func mockProvider(from record: AgentRecord) -> MockLLMProvider {
        let scenes = record.steps.map(Self.scene(from:))
        return MockLLMProvider(scenes: scenes)
    }

    // MARK: - State replay

    /// Decode every node visit's input + output state in a graph
    /// record back to `State`. Throws on the first decode failure so
    /// schema mismatches surface loudly in tests.
    public static func states<State: Decodable & Sendable>(
        from record: StateGraphRecord,
        as type: State.Type
    ) throws -> [StateTransition<State>] {
        let decoder = JSONDecoder()
        return try record.nodes.map { node in
            try StateTransition(
                node: node.name,
                input: decoder.decode(type, from: node.inputState),
                output: decoder.decode(type, from: node.outputState),
                durationSeconds: node.durationSeconds
            )
        }
    }

    // MARK: Private

    private static func scene(from step: AgentStepRecord) -> MockLLMProvider.Scene {
        var events: [ProviderEvent] = [.messageStart(messageId: UUID().uuidString)]
        let newMessages = step.messagesAfter.dropFirst(step.messagesBefore.count)
        let extraction = Self.extract(from: Array(newMessages))

        if !extraction.assistantText.isEmpty {
            events.append(.textDelta(extraction.assistantText))
        }
        // Use toolCallStart/toolCallEnd so the replay agent's own
        // tool registry handles dispatch — using toolCallExecuted
        // here would land in the agent's preExecuted path and
        // terminate the loop, preventing follow-up steps from
        // playing back.
        for call in extraction.toolCalls {
            events.append(.toolCallStart(call))
            events.append(.toolCallEnd(id: call.id))
        }

        // The recorded finish reason isn't surfaced per-step, so
        // infer: if tool calls fired the model's turn ended with
        // `.toolUse`; otherwise `.endTurn`.
        let reason: FinishReason = extraction.toolCalls.isEmpty ? .endTurn : .toolUse
        events.append(.messageStop(reason))
        return MockLLMProvider.Scene(events)
    }

    private static func extract(from messages: [Message]) -> StepExtraction {
        var assistantText = ""
        var toolCalls: [ToolCall] = []
        var toolResults: [String: JSONValue] = [:]
        for message in messages {
            switch message.role {
            case .assistant:
                assistantText += message.textContent
                toolCalls.append(contentsOf: message.toolCalls)
            case .tool:
                guard let callId = message.toolCallId else {
                    continue
                }
                let text = message.textContent
                let parsed = (try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)))
                    ?? .string(text)
                toolResults[callId] = parsed
            default:
                continue
            }
        }
        return StepExtraction(
            assistantText: assistantText,
            toolCalls: toolCalls,
            toolResults: toolResults
        )
    }
}

// MARK: - StateTransition

/// One decoded node visit from a recorded `StateGraphRecord`.
public struct StateTransition<State: Sendable>: Sendable {
    // MARK: Lifecycle

    public init(node: String, input: State, output: State, durationSeconds: Double) {
        self.node = node
        self.input = input
        self.output = output
        self.durationSeconds = durationSeconds
    }

    // MARK: Public

    public let node: String
    public let input: State
    public let output: State
    public let durationSeconds: Double
}

// MARK: - StepExtraction

private struct StepExtraction {
    let assistantText: String
    let toolCalls: [ToolCall]
    let toolResults: [String: JSONValue]
}
