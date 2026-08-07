import Foundation
import XCTest
@testable import Aria
import AriaTesting

// MARK: - ContextAssemblyIntegrationTests

/// Asserts on what the *provider actually receives*.
///
/// The unit tests around `DefaultContextAssembler` prove the assembler
/// computes the right answer. These prove the agent loop delivers that
/// answer to the provider — and, just as importantly, that consumers
/// who never opt in see no change at all.
final class ContextAssemblyIntegrationTests: XCTestCase {
    // MARK: - Backwards compatibility

    /// The load-bearing guarantee of this whole feature.
    ///
    /// Aria is consumed behind exact-version pins, so a context change
    /// that altered requests for callers who didn't ask for it would be
    /// a silent behavioural break in shipped apps. With no assembler
    /// configured the request must be identical to what the loop built
    /// before the hook existed: system prompt prepended, every
    /// registered tool sent, history untouched.
    func testNilAssemblerLeavesTheRequestUnchanged() async throws {
        let provider = MockLLMProvider(scenes: [.text("ok")])
        let tools = (0..<5).map { Self.tool(named: "tool_\($0)", description: "Unrelated \($0).") }
        let agent = Agent(config: AgentConfig(
            provider: provider,
            tools: tools,
            systemPrompt: "You are a concise assistant."
        ))

        _ = try await self.drain(agent.stream(.message(.user("hello"))))

        let invocation = try XCTUnwrap(provider.invocations.first)
        XCTAssertEqual(invocation.tools.count, 5, "Every tool must still be sent")
        XCTAssertEqual(invocation.messages.first?.role, .system)
        XCTAssertEqual(invocation.messages.first?.textContent, "You are a concise assistant.")
        XCTAssertEqual(invocation.messages.last?.textContent, "hello")
    }

    // MARK: - Assembler engaged

    func testAssemblerCapsToolsReachingTheProvider() async throws {
        let provider = MockLLMProvider(scenes: [.text("ok")])
        let tools = [
            Self.tool(named: "get_weather", description: "Weather for a city."),
            Self.tool(named: "convert_currency", description: "Convert between currencies."),
            Self.tool(named: "rotate_image", description: "Rotate an image."),
        ]
        let agent = Agent(config: AgentConfig(
            provider: provider,
            tools: tools,
            systemPrompt: "System.",
            contextAssembler: DefaultContextAssembler(),
            contextBudget: ContextBudget(total: 8192, maxTools: 1)
        ))

        _ = try await self.drain(agent.stream(.message(.user("what is the weather in Paris"))))

        let invocation = try XCTUnwrap(provider.invocations.first)
        XCTAssertEqual(invocation.tools.count, 1)
        XCTAssertEqual(invocation.tools.first?.name, "get_weather")
    }

    /// Guidance reaching the model is gated on the tool reaching the
    /// model — the property that makes "policy for a tool that isn't
    /// registered" unrepresentable.
    func testGuidanceForUnselectedToolNeverReachesProvider() async throws {
        let provider = MockLLMProvider(scenes: [.text("ok")])
        let tools = [
            Self.tool(
                named: "get_weather",
                description: "Weather for a city.",
                guidance: "Report current conditions."
            ),
            Self.tool(
                named: "remember_fact",
                description: "Store a durable fact about the user.",
                guidance: "Store durable first-person facts the user states."
            ),
        ]
        let agent = Agent(config: AgentConfig(
            provider: provider,
            tools: tools,
            systemPrompt: "System.",
            contextAssembler: DefaultContextAssembler(),
            contextBudget: ContextBudget(total: 8192, maxTools: 1)
        ))

        _ = try await self.drain(agent.stream(.message(.user("weather in Paris"))))

        let invocation = try XCTUnwrap(provider.invocations.first)
        let systemText = invocation.messages
            .filter { $0.role == .system }
            .map(\.textContent)
            .joined(separator: "\n")
        XCTAssertTrue(systemText.contains("Report current conditions."))
        XCTAssertFalse(systemText.contains("Store durable first-person facts the user states."))
    }

    /// When the caller supplies no budget, the agent derives one from
    /// the provider — preferring the usable window over the advertised
    /// one, which is the entire point of distinguishing them.
    func testBudgetIsDerivedFromUsableContextWhenNotSupplied() async throws {
        let capabilities = ProviderCapabilities(
            modelIdentifier: "test/model",
            supportsToolUse: true,
            maxContextTokens: 128_000,
            usableContextTokens: 256
        )
        let provider = MockLLMProvider(scenes: [.text("ok")], capabilities: capabilities)
        let history = (0..<80).map { Message.user("filler message number \($0) padding it out") }
        let agent = Agent(config: AgentConfig(
            provider: provider,
            systemPrompt: "System.",
            contextAssembler: DefaultContextAssembler()
        ))

        var input = history
        input.append(.user("final question"))
        _ = try await self.drain(agent.stream(.messages(input)))

        let invocation = try XCTUnwrap(provider.invocations.first)
        XCTAssertLessThan(
            invocation.messages.count,
            input.count,
            "A 256-token usable window must force trimming; the advertised 128k must not be used"
        )
        XCTAssertEqual(invocation.messages.last?.textContent, "final question")
    }

    // MARK: - Helpers

    private func drain(
        _ stream: AsyncThrowingStream<AgentEvent, any Error>
    ) async throws -> [AgentEvent] {
        var events: [AgentEvent] = []
        for try await event in stream {
            events.append(event)
        }
        return events
    }

    private static func tool(
        named name: String,
        description: String,
        guidance: String? = nil
    ) -> AnyTool {
        AnyTool(
            definition: ToolDefinition(
                name: name,
                description: description,
                inputSchema: .object(properties: ["value": .string()], required: []),
                promptGuidance: guidance
            ),
            invoke: { _, _ in .null }
        )
    }
}
