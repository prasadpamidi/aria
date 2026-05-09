import Foundation

// MARK: - AgentInput

/// What you send to an agent's `stream` method.
///
/// PR 3 supports the simple turn shapes: a single user message, or a
/// batch of messages prepared elsewhere (e.g., reconstructed from a
/// conversation store before the agent runs). `resume(threadId:)` will
/// arrive with the `Checkpointer` in a later PR.
public enum AgentInput: Sendable {
    case message(Message)
    case messages([Message])
}

extension AgentInput {
    /// All messages this input contributes to the agent's state.
    var messages: [Message] {
        switch self {
        case let .message(value): [value]
        case let .messages(values): values
        }
    }
}
