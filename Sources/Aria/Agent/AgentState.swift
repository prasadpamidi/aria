import Foundation

// MARK: - AgentState

/// The mutable state the agent threads through its control loop.
///
/// `AgentState` is a value type; middleware receives it and returns a
/// (possibly modified) copy. The agent applies the returned value before
/// proceeding — there is no shared mutable object.
public struct AgentState: Sendable, Codable {
    // MARK: Lifecycle

    public init(
        threadId: String = UUID().uuidString,
        messages: [Message] = [],
        stepCount: Int = 0,
        scratchpad: [String: JSONValue] = [:],
        lastFinishReason: FinishReason? = nil
    ) {
        self.threadId = threadId
        self.messages = messages
        self.stepCount = stepCount
        self.scratchpad = scratchpad
        self.lastFinishReason = lastFinishReason
    }

    // MARK: Public

    public let threadId: String
    public var messages: [Message]
    public var stepCount: Int
    public var scratchpad: [String: JSONValue]
    public var lastFinishReason: FinishReason?
}
