import Aria
import AriaApple
import Foundation
import FoundationModels

// MARK: - HaikuChainState

/// State threaded through the haiku-chain `StateGraph` demo. Each node
/// fills in the next field via an `Aria.Agent` call routed through the
/// `addAgentNode` helper.
///
/// `nonisolated` opts out of AriaSample's MainActor-by-default
/// isolation so the synthesized `Codable` + `Sendable` conformances
/// can satisfy `StateGraph<State: Sendable & Codable>`.
@available(iOS 26.0, macOS 26.0, *)
nonisolated struct HaikuChainState: Codable {
    var topic: String?
    var haiku: String?
    var critique: String?
}

// MARK: - HaikuChain

/// Three-node linear graph used by AriaSample's "Graph" button:
/// `brainstorm → haiku → critique → end`. Each node uses
/// `StateGraph.addAgentNode` so the V2 ergonomic helper is exercised
/// end-to-end (was: hand-rolled LanguageModelSession calls in V1).
@available(iOS 26.0, macOS 26.0, *)
enum HaikuChain {
    /// Demo-wide checkpoint thread id. Stable so the Resume button can
    /// pick up runs across app launches when the persistent
    /// `GRDBCheckpointer` is wired in.
    static let threadId = "haiku-graph-default"

    /// Build and validate the demo graph. Returns a runnable
    /// `CompiledStateGraph` ready to stream events. The agent passed
    /// in is reused across all three nodes — `Agent` is `Sendable`
    /// so this is safe.
    static func build(agent: Agent) throws -> CompiledStateGraph<HaikuChainState> {
        var graph = StateGraph<HaikuChainState>()

        graph.addAgentNode(
            "brainstorm",
            agent: agent,
            prompt: { _ in
                "Pick one creative, evocative topic for a haiku in 1-4 words. "
                    + "Reply with only the topic, no quotes or punctuation."
            },
            writeResult: { state, text in
                state.topic = text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        )

        graph.addAgentNode(
            "haiku",
            agent: agent,
            prompt: { state in
                let topic = state.topic ?? "silence"
                return "Write a haiku about \(topic). 5-7-5 syllables across three "
                    + "lines. Reply with only the haiku."
            },
            writeResult: { state, text in
                state.haiku = text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        )

        graph.addAgentNode(
            "critique",
            agent: agent,
            prompt: { state in
                let haiku = state.haiku ?? "(no haiku)"
                return "In one short sentence, critique this haiku for imagery and "
                    + "rhythm:\n\(haiku)"
            },
            writeResult: { state, text in
                state.critique = text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        )

        graph.setEntry("brainstorm")
        graph.addEdge(from: "brainstorm", to: "haiku")
        graph.addEdge(from: "haiku", to: "critique")
        graph.addEdge(from: "critique", to: StateGraph<HaikuChainState>.end)

        return try graph.build()
    }

    /// Build a fresh agent backed by `FoundationModelsProvider`, with
    /// no tools and no middleware — the graph drives the orchestration.
    static func makeAgent() -> Agent {
        Agent(config: AgentConfig(
            provider: FoundationModelsProvider(),
            tools: [],
            threadId: "haiku-agent"
        ))
    }
}
