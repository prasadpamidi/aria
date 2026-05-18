import Aria
import AriaApple
import Foundation
import FoundationModels

// MARK: - RememberTool

/// A tool the model can call to save a fact for later recall.
///
/// Demonstrates the agent + memory loop end-to-end:
/// 1. The user says something worth remembering ("I prefer metric units").
/// 2. The system prompt nudges the model to call `remember_fact` when it
///    learns something durable about the user.
/// 3. On a future turn, `RAGMiddleware` retrieves the stored fact and
///    injects it as context before the next provider call.
///
/// Conforms to `GenerableTool` so the FoundationModels tool router can
/// resolve calls against the typed `Input` struct.
struct RememberTool: GenerableTool {
    @Generable
    struct Input: Codable {
        @Guide(description: "A concise statement of the fact to remember.")
        var fact: String
    }

    struct Output: Codable {
        let stored: Bool
        let id: String
    }

    static let name = "remember_fact"
    static let description = """
    Save a durable fact about the user (preferences, biographical info, \
    long-lived context). Call this when the user shares something they \
    will want you to remember in future conversations.
    """

    static var inputSchema: JSONSchema {
        .object(
            properties: [
                "fact": .string(
                    description: "A concise statement of the fact to remember."
                ),
            ],
            required: ["fact"]
        )
    }

    let memoryStore: any MemoryStore
    let namespace: [String]

    func call(_ input: Input, context _: ToolContext) async throws -> Output {
        let item = MemoryItem(content: input.fact)
        let ref = try await memoryStore.remember(item, namespace: self.namespace)
        return Output(stored: true, id: ref.id)
    }
}
