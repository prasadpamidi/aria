import Foundation

// MARK: - SessionBundle

/// A self-contained, JSON-serializable record of an agent run, a
/// `StateGraph` run, or both. Designed to be shipped to a backend or
/// shared between machines so the same trajectory can be inspected,
/// replayed, or simulated without re-running the model.
///
/// The bundle captures every input / output / state transition the
/// runtime saw — message log, tool calls + results, per-step state,
/// per-graph-node input/output state. Decoding it on another machine
/// gives a complete picture of what happened.
public struct SessionBundle: Codable, Sendable, Equatable {
    // MARK: Lifecycle

    public init(
        id: String = UUID().uuidString,
        createdAt: Date = Date(),
        version: String = "1",
        agent: AgentRecord? = nil,
        stateGraph: StateGraphRecord? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.version = version
        self.agent = agent
        self.stateGraph = stateGraph
    }

    // MARK: Public

    public let id: String
    public let createdAt: Date
    /// Bundle schema version; bumped when the wire format changes.
    public let version: String
    public let agent: AgentRecord?
    public let stateGraph: StateGraphRecord?
}

// MARK: - AgentRecord

/// Captures one full agent run: input messages, every step the loop
/// took, tool calls + results, and the final message log.
public struct AgentRecord: Codable, Sendable, Equatable {
    // MARK: Lifecycle

    public init(
        threadId: String,
        providerSystem: String,
        providerModel: String,
        systemPrompt: String?,
        inputMessages: [Message],
        steps: [AgentStepRecord],
        finalMessages: [Message],
        finishReason: FinishReason?
    ) {
        self.threadId = threadId
        self.providerSystem = providerSystem
        self.providerModel = providerModel
        self.systemPrompt = systemPrompt
        self.inputMessages = inputMessages
        self.steps = steps
        self.finalMessages = finalMessages
        self.finishReason = finishReason
    }

    // MARK: Public

    public let threadId: String
    public let providerSystem: String
    public let providerModel: String
    public let systemPrompt: String?
    public let inputMessages: [Message]
    public let steps: [AgentStepRecord]
    public let finalMessages: [Message]
    public let finishReason: FinishReason?
}

// MARK: - AgentStepRecord

/// One step of the agent loop: state at the boundaries. Tool calls
/// + their results live in `messagesAfter` as the standard
/// `Message.assistant(toolCalls:)` + `Message.tool(callId:text:)`
/// pairs — replayers extract them from the diff with `messagesBefore`.
public struct AgentStepRecord: Codable, Sendable, Equatable {
    // MARK: Lifecycle

    public init(
        index: Int,
        messagesBefore: [Message],
        messagesAfter: [Message]
    ) {
        self.index = index
        self.messagesBefore = messagesBefore
        self.messagesAfter = messagesAfter
    }

    // MARK: Public

    public let index: Int
    public let messagesBefore: [Message]
    public let messagesAfter: [Message]
}

// MARK: - StateGraphRecord

/// Captures a `StateGraph` run: every node's input + output state,
/// in the order the runner visited them.
public struct StateGraphRecord: Codable, Sendable, Equatable {
    // MARK: Lifecycle

    public init(nodes: [StateGraphNodeRecord]) {
        self.nodes = nodes
    }

    // MARK: Public

    public let nodes: [StateGraphNodeRecord]
}

// MARK: - StateGraphNodeRecord

/// One node visit in a graph run. State is stored as JSON-encoded
/// `Data` so the bundle is generic over the consumer's `State` type;
/// decoders restore it via `JSONDecoder().decode(State.self, from:)`.
public struct StateGraphNodeRecord: Codable, Sendable, Equatable {
    // MARK: Lifecycle

    public init(
        name: String,
        inputState: Data,
        outputState: Data,
        durationSeconds: Double
    ) {
        self.name = name
        self.inputState = inputState
        self.outputState = outputState
        self.durationSeconds = durationSeconds
    }

    // MARK: Public

    public let name: String
    public let inputState: Data
    public let outputState: Data
    public let durationSeconds: Double
}
