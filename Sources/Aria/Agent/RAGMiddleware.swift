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
        minimumScore: Float? = nil,
        instructionPrefix: String = "Relevant memories that may help:",
        onRecall: (@Sendable ([MemoryMatch]) -> Void)? = nil
    ) {
        self.memoryStore = memoryStore
        self.namespace = namespace
        self.topK = topK
        self.minimumScore = minimumScore
        self.instructionPrefix = instructionPrefix
        self.onRecall = onRecall
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

        let candidates = try await memoryStore.recall(
            query: userText,
            namespace: self.namespace,
            topK: self.topK,
            filter: nil
        )
        // Recall only what relates to the turn, when the caller has
        // calibrated a floor.
        //
        // Defaults to `nil` — off — on purpose. The right value is a
        // property of the embedder, not of this file: cosine
        // distributions differ enough between models that a number
        // tuned for one silently returns nothing for another, and a
        // memory system that recalls nothing looks identical to one
        // with an empty store. Callers that know their embedder pass a
        // floor; nobody inherits a guess.
        //
        // `recall` returns the top *k* by similarity, which is not the
        // same as "relevant" — with a small store it returns the same
        // handful every time regardless of the question. In the field
        // that meant "user lives in Berlin" was injected into a
        // fasting-status query, on every turn, forever.
        //
        // Unrelated memories are not free. They cost budget, they
        // invite the model to weave them into answers, and they make
        // the recall UI meaningless because it always says the same
        // thing.
        let relevant = self.minimumScore.map { floor in
            candidates.filter { $0.score >= floor }
        } ?? candidates
        guard !relevant.isEmpty else {
            return state
        }
        let matches = relevant
        // Surface what was recalled so callers (UI inspectors, logs)
        // can see the retrieval result without having to re-issue the
        // query themselves.
        self.onRecall?(matches)

        let context = matches
            .map { "- \($0.item.content)" }
            .joined(separator: "\n")
        let memoryMessage = Message.system("\(self.instructionPrefix)\n\(context)")

        var newState = state
        // Drop the blocks this middleware wrote on earlier turns.
        //
        // Recall is per-turn context, not an instruction, and it was
        // accumulating without limit: every turn inserted a fresh block
        // and the assembler preserves system messages by design — it
        // cannot tell a recalled-memory block from the instructions it
        // must never trim.
        //
        // Seen in a trace: one prompt carried "## Recalled memories"
        // twice, listing the same two facts in different orders,
        // because each turn had re-retrieved and re-inserted them. Two
        // blocks disagree about nothing and still cost tokens and
        // credibility; by turn ten there would have been ten.
        newState.messages.removeAll { message in
            message.role == .system && message.textContent.hasPrefix(self.instructionPrefix)
        }
        let insertionIndex = Self.lastUserMessageIndex(in: newState.messages) ?? newState.messages.count
        newState.messages.insert(memoryMessage, at: insertionIndex)
        return newState
    }

    // MARK: Private

    private let memoryStore: any MemoryStore
    private let namespace: [String]
    private let topK: Int
    private let minimumScore: Float?
    private let instructionPrefix: String
    private let onRecall: (@Sendable ([MemoryMatch]) -> Void)?

    private static func lastUserText(in messages: [Message]) -> String? {
        messages.last(where: { $0.role == .user })?.textContent
    }

    private static func lastUserMessageIndex(in messages: [Message]) -> Int? {
        messages.lastIndex(where: { $0.role == .user })
    }
}
