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
    ///   registry. Pair with `tools(from:)` to swap in a registry
    ///   that returns the recorded outputs deterministically — useful
    ///   when the original tools were I/O-heavy or non-deterministic.
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

    // MARK: - Tool replay

    /// Build a list of `AnyTool`s that return the recorded outputs
    /// instead of dispatching live tools.
    ///
    /// Pair with `mockProvider(from:)` to make a replay deterministic
    /// for I/O-heavy tools whose live invocation would diverge from
    /// the recording. Each tool consumes its recorded calls in order
    /// — the first call to a name pops the first recorded invocation
    /// of that name, the second pops the second, and so on. Argument
    /// equality is checked first; if no match is found, the
    /// next-in-queue result is returned (lenient for inputs that drift
    /// between record and replay).
    ///
    /// The returned tools advertise an empty object schema because
    /// the bundle doesn't carry the original tool definitions; for
    /// agents that validate schemas, register the production tool
    /// definitions separately.
    public static func tools(from record: AgentRecord) -> [AnyTool] {
        var byName: [String: [RecordedCall]] = [:]
        for step in record.steps {
            let new = Array(step.messagesAfter.dropFirst(step.messagesBefore.count))
            let extraction = Self.extract(from: new)
            for call in extraction.toolCalls {
                let result = extraction.toolResults[call.id] ?? .null
                byName[call.name, default: []].append(
                    RecordedCall(arguments: call.arguments, result: result)
                )
            }
        }

        let store = ReplayToolStore(callsByName: byName)
        return byName.keys.map { name in
            AnyTool(
                definition: ToolDefinition(
                    name: name,
                    description: "Replay of recorded '\(name)' calls",
                    inputSchema: .object(properties: [:], required: [])
                ),
                invoke: { arguments, _ in
                    await store.consume(name: name, arguments: arguments)
                }
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

// MARK: - RecordedCall

/// One captured `(arguments, result)` pair for a tool name.
private struct RecordedCall {
    let arguments: JSONValue
    let result: JSONValue
}

// MARK: - ReplayToolStore

/// Actor-isolated FIFO queue of recorded tool calls keyed by tool
/// name. Each `consume(...)` pops the first matching (or
/// next-in-queue) entry so replays drain the recording exactly once.
private actor ReplayToolStore {
    // MARK: Lifecycle

    init(callsByName: [String: [RecordedCall]]) {
        self.callsByName = callsByName
    }

    // MARK: Internal

    func consume(name: String, arguments: JSONValue) -> JSONValue {
        guard var queue = self.callsByName[name], !queue.isEmpty else {
            return .null
        }
        // Prefer an exact-arguments match so re-orderings or
        // duplicate-name calls with different args still resolve
        // correctly. Fall back to the next-in-queue entry when no
        // arguments match — covers light non-determinism in inputs.
        let chosenIndex = queue.firstIndex(where: { $0.arguments == arguments }) ?? 0
        let match = queue.remove(at: chosenIndex)
        self.callsByName[name] = queue
        return match.result
    }

    // MARK: Private

    private var callsByName: [String: [RecordedCall]]
}
