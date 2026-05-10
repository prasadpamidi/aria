import Foundation

// MARK: - RecordingMiddleware

/// `AgentMiddleware` that streams every lifecycle hook into a
/// `SessionRecorder`. Add it to `AgentConfig.middleware` to start
/// capturing the run; pull a `SessionBundle` off the recorder when
/// you need to ship the result.
///
/// Implementation note: the middleware runs *last* in the chain so
/// `messagesAfter` reflects the full state any other middleware
/// modified during `afterStep`.
public final class RecordingMiddleware: AgentMiddleware, @unchecked Sendable {
    // MARK: Lifecycle

    public init(recorder: SessionRecorder) {
        self.recorder = recorder
    }

    // MARK: Public

    public func beforeRun(_ state: AgentState) async throws -> AgentState {
        let provider = self.providerInfo
        await self.recorder.startAgentRun(
            threadId: state.threadId,
            providerSystem: provider.system,
            providerModel: provider.model,
            systemPrompt: self.cachedSystemPrompt,
            inputMessages: state.messages
        )
        self.locked { self.lastSeenMessageCount[state.threadId] = state.messages.count }
        return state
    }

    public func beforeStep(_ state: AgentState) async throws -> AgentState {
        self.locked { self.beforeStepMessages[state.threadId] = state.messages }
        return state
    }

    public func afterStep(_ state: AgentState) async throws -> AgentState {
        let before = self.locked { self.beforeStepMessages[state.threadId] ?? [] }
        let stepIndex = self.locked { () -> Int in
            let index = self.stepCounter[state.threadId, default: 0]
            self.stepCounter[state.threadId] = index + 1
            return index
        }
        await self.recorder.recordAgentStep(
            index: stepIndex,
            messagesBefore: before,
            messagesAfter: state.messages
        )
        return state
    }

    public func afterRun(
        _ state: AgentState,
        finalEvent: AgentEvent
    ) async throws -> AgentState {
        let reason = Self.finishReason(from: finalEvent)
        await self.recorder.finishAgentRun(
            finalMessages: state.messages,
            finishReason: reason ?? .endTurn
        )
        return state
    }

    /// Capture the agent's provider identity + system prompt before
    /// the first run starts. The agent itself doesn't surface them to
    /// middleware otherwise; consumers call this once during setup.
    public func bind(
        providerSystem: String,
        providerModel: String,
        systemPrompt: String?
    ) {
        self.locked {
            self.providerInfo = (providerSystem, providerModel)
            self.cachedSystemPrompt = systemPrompt
        }
    }

    // MARK: Private

    private let recorder: SessionRecorder
    private let lock = NSLock()
    private var beforeStepMessages: [String: [Message]] = [:]
    private var stepCounter: [String: Int] = [:]
    private var lastSeenMessageCount: [String: Int] = [:]
    private var providerInfo: (system: String, model: String) = ("unknown", "unknown")
    private var cachedSystemPrompt: String?

    private static func finishReason(from event: AgentEvent) -> FinishReason? {
        if case let .finish(reason) = event {
            return reason
        }
        return nil
    }

    private func locked<T>(_ block: () -> T) -> T {
        self.lock.lock()
        defer { self.lock.unlock() }
        return block()
    }
}
