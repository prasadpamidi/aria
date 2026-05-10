import Aria
import Foundation
import FoundationModels

// MARK: - HaikuChainState

/// State threaded through the haiku-chain `StateGraph` demo. Each node
/// fills in the next field by making an on-device FoundationModels
/// call.
///
/// `nonisolated` opts out of AriaSample's MainActor-by-default
/// isolation so the synthesized `Codable` + `Sendable` conformances
/// can satisfy `StateGraph<State: Sendable & Codable>`. Without it,
/// the conformances become MainActor-isolated and the generic
/// constraint rejects them.
@available(iOS 26.0, macOS 26.0, *)
nonisolated struct HaikuChainState: Codable {
    var topic: String?
    var haiku: String?
    var critique: String?
}

// MARK: - HaikuChain

/// Three-node linear graph used by AriaSample's "Graph" button:
/// `brainstorm → haiku → critique → end`. Each node makes a fresh
/// `LanguageModelSession` call; output of one node feeds the prompt of
/// the next via the threaded `HaikuChainState` value.
@available(iOS 26.0, macOS 26.0, *)
enum HaikuChain {
    // MARK: Internal

    /// Build and validate the demo graph. Returns a runnable
    /// `CompiledStateGraph` ready to stream events.
    static func build() throws -> CompiledStateGraph<HaikuChainState> {
        var graph = StateGraph<HaikuChainState>()

        graph.addNode("brainstorm") { state in
            let topic = try await Self.respond(
                "Pick one creative, evocative topic for a haiku in 1-4 words. "
                    + "Reply with only the topic, no quotes or punctuation."
            )
            var copy = state
            copy.topic = topic.trimmingCharacters(in: .whitespacesAndNewlines)
            return copy
        }

        graph.addNode("haiku") { state in
            let topic = state.topic ?? "silence"
            let haiku = try await Self.respond(
                "Write a haiku about \(topic). 5-7-5 syllables across three lines. "
                    + "Reply with only the haiku."
            )
            var copy = state
            copy.haiku = haiku.trimmingCharacters(in: .whitespacesAndNewlines)
            return copy
        }

        graph.addNode("critique") { state in
            let haiku = state.haiku ?? "(no haiku)"
            let critique = try await Self.respond(
                "In one short sentence, critique this haiku for imagery and "
                    + "rhythm:\n\(haiku)"
            )
            var copy = state
            copy.critique = critique.trimmingCharacters(in: .whitespacesAndNewlines)
            return copy
        }

        graph.setEntry("brainstorm")
        graph.addEdge(from: "brainstorm", to: "haiku")
        graph.addEdge(from: "haiku", to: "critique")
        graph.addEdge(from: "critique", to: StateGraph<HaikuChainState>.end)

        return try graph.build()
    }

    // MARK: Private

    /// Single-shot `LanguageModelSession.respond(to:)` wrapper. Kept
    /// local to the demo so the StateGraph nodes don't need to know
    /// about the wider Aria provider plumbing — useful for showing the
    /// graph composes cleanly with raw FM calls too.
    private static func respond(_ prompt: String) async throws -> String {
        let session = LanguageModelSession()
        let response = try await session.respond(to: prompt)
        return response.content
    }
}
