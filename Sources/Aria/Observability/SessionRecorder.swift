import Foundation

// MARK: - SessionRecorder

/// Captures agent + state-graph events into a shippable
/// `SessionBundle`. Hand the same recorder to both the agent
/// (via `RecordingMiddleware`) and the state graph (via
/// `RunOptions.recorder`) and a single `bundle()` call returns
/// everything that happened.
///
/// Concurrency: actor-isolated so the agent and the graph can record
/// concurrently without races.
public actor SessionRecorder {
    // MARK: Lifecycle

    public init() { }

    // MARK: Public

    // MARK: Public — Agent

    /// Record the start of an agent run. Captures the model identity
    /// + thread + initial input messages.
    public func startAgentRun(
        threadId: String,
        providerSystem: String,
        providerModel: String,
        systemPrompt: String?,
        inputMessages: [Message]
    ) {
        self.agentInfo = AgentRunInfo(
            threadId: threadId,
            providerSystem: providerSystem,
            providerModel: providerModel,
            systemPrompt: systemPrompt,
            inputMessages: inputMessages,
            steps: [],
            finalMessages: [],
            finishReason: nil
        )
    }

    /// Record one completed step. `messagesBefore` is the state's
    /// message list as the step began; `messagesAfter` reflects the
    /// state once `afterStep` middleware has run. `toolCalls` lists
    /// every tool the model invoked during the step.
    public func recordAgentStep(
        index: Int,
        messagesBefore: [Message],
        messagesAfter: [Message]
    ) {
        guard var info = self.agentInfo else {
            return
        }
        info.steps.append(AgentStepRecord(
            index: index,
            messagesBefore: messagesBefore,
            messagesAfter: messagesAfter
        ))
        self.agentInfo = info
    }

    /// Record the agent run finishing. `finalMessages` is the message
    /// list after `afterRun` middleware; `finishReason` is the
    /// terminal event's reason.
    public func finishAgentRun(
        finalMessages: [Message],
        finishReason: FinishReason
    ) {
        guard var info = self.agentInfo else {
            return
        }
        info.finalMessages = finalMessages
        info.finishReason = finishReason
        self.agentInfo = info
    }

    // MARK: Public — StateGraph

    /// Record one node visit. State payloads are pre-encoded JSON
    /// `Data` so the recorder doesn't need to know the consumer's
    /// `State` generic type.
    public func recordStateGraphNode(
        name: String,
        inputState: Data,
        outputState: Data,
        durationSeconds: Double
    ) {
        self.stateGraphNodes.append(StateGraphNodeRecord(
            name: name,
            inputState: inputState,
            outputState: outputState,
            durationSeconds: durationSeconds
        ))
    }

    // MARK: Public — Export

    /// Build the bundle from everything recorded so far. Repeated
    /// calls are safe and return up-to-date snapshots; the recorder
    /// itself is not mutated.
    public func bundle() -> SessionBundle {
        SessionBundle(
            agent: self.agentInfo.map(\.asRecord),
            stateGraph: self.stateGraphNodes.isEmpty
                ? nil
                : StateGraphRecord(nodes: self.stateGraphNodes)
        )
    }

    // MARK: Private

    private var agentInfo: AgentRunInfo?
    private var stateGraphNodes: [StateGraphNodeRecord] = []
}

// MARK: - AgentRunInfo

/// Mirror of `AgentRecord` with a mutable shape. Internal scratch
/// state for the recorder; converted via `asRecord` on `bundle()`.
private struct AgentRunInfo {
    var threadId: String
    var providerSystem: String
    var providerModel: String
    var systemPrompt: String?
    var inputMessages: [Message]
    var steps: [AgentStepRecord]
    var finalMessages: [Message]
    var finishReason: FinishReason?

    var asRecord: AgentRecord {
        AgentRecord(
            threadId: self.threadId,
            providerSystem: self.providerSystem,
            providerModel: self.providerModel,
            systemPrompt: self.systemPrompt,
            inputMessages: self.inputMessages,
            steps: self.steps,
            finalMessages: self.finalMessages,
            finishReason: self.finishReason
        )
    }
}
