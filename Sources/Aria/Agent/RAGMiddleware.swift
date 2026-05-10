import Foundation

// MARK: - RAGMiddleware

/// Retrieves memories relevant to the latest user message and injects
/// them into the agent's state as a system message before the first
/// step runs.
///
/// Only fires on `state.stepCount == 0` so multi-step tool-calling runs
/// don't accumulate retrieval context across iterations.
public final class RAGMiddleware: AgentMiddleware, @unchecked Sendable {
    // MARK: Lifecycle

    public init(
        memoryStore: any MemoryStore,
        namespace: [String],
        topK: Int = 5,
        instructionPrefix: String = "Relevant memories that may help:"
    ) {
        self.memoryStore = memoryStore
        self.namespace = namespace
        self.topK = topK
        self.instructionPrefix = instructionPrefix
    }

    // MARK: Public

    public func beforeStep(_ state: AgentState) async throws -> AgentState {
        guard state.stepCount == 0 else {
            return state
        }
        guard let userText = Self.lastUserText(in: state.messages),
              !userText.isEmpty else {
            return state
        }

        let matches = try await memoryStore.recall(
            query: userText,
            namespace: self.namespace,
            topK: self.topK,
            filter: nil
        )
        guard !matches.isEmpty else {
            return state
        }

        let context = matches
            .map { "- \($0.item.content)" }
            .joined(separator: "\n")
        let memoryMessage = Message.system("\(self.instructionPrefix)\n\(context)")

        var newState = state
        let insertionIndex = Self.lastUserMessageIndex(in: newState.messages) ?? newState.messages.count
        newState.messages.insert(memoryMessage, at: insertionIndex)
        return newState
    }

    // MARK: Private

    private let memoryStore: any MemoryStore
    private let namespace: [String]
    private let topK: Int
    private let instructionPrefix: String

    private static func lastUserText(in messages: [Message]) -> String? {
        messages.last(where: { $0.role == .user })?.textContent
    }

    private static func lastUserMessageIndex(in messages: [Message]) -> Int? {
        messages.lastIndex(where: { $0.role == .user })
    }
}
