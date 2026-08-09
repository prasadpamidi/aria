@testable import Aria
import XCTest

/// `maxTools` bounds how *many* tools are sent; `toolTokenLimit` bounds
/// what they *cost*. Only the count was enforced once ranking returned
/// something, so a small number of large schemas could still overflow
/// the window — which is exactly what a connected MCP server did:
/// 5,845 tokens into a 4,096-token window, with the budget reporting
/// itself satisfied.
final class ToolBudgetCeilingTests: XCTestCase {
    /// The regression. Six large tools sit under `maxTools: 6` and far
    /// over the token ceiling.
    func testRankedToolsAreTrimmedToTheTokenCeiling() async throws {
        let tools = (0 ..< 6).map { Self.tool(named: "weather_\($0)", descriptionLength: 1200) }
        let budget = ContextBudget(total: 4096, reservedForOutput: 768, maxTools: 6)
        let assembler = DefaultContextAssembler(unrankedFillLimit: 0)

        let request = await assembler.assemble(
            systemPrompt: "You are helpful.",
            tools: tools,
            state: Self.state(query: "what is the weather"),
            budget: budget
        )

        let counter = HeuristicTokenCounter()
        let spent = request.tools.reduce(0) { $0 + counter.count(tool: $1.definition) }
        XCTAssertLessThanOrEqual(
            spent,
            budget.toolTokenLimit,
            "selected \(request.tools.count) tools costing \(spent) against a ceiling of \(budget.toolTokenLimit)"
        )
        XCTAssertFalse(
            request.tools.isEmpty,
            "trimming to nothing would make the turn unable to act"
        )
    }

    /// The regression from the field: ranking chose the right tool and
    /// the share admitted none of them, leaving a turn that could only
    /// answer from imagination.
    ///
    /// A single MCP schema on a real server runs to roughly a thousand
    /// tokens, which is over the share once a pinned tool has taken its
    /// cut. Respecting the share exactly is right when it costs a
    /// fourth tool and wrong when it costs the only one.
    func testTopRankedToolSurvivesEvenWhenItBustsTheShare() async throws {
        let huge = Self.tool(named: "weather_summary", descriptionLength: 6000)
        let pinned = Self.tool(named: "load_skill", descriptionLength: 40)
        let assembler = DefaultContextAssembler(
            pinnedToolNames: ["load_skill"],
            unrankedFillLimit: 0
        )
        var state = AgentState()
        state.messages = [.user("weather summary please")]

        let assembled = await assembler.assemble(
            systemPrompt: "You are helpful.",
            tools: [pinned, huge],
            state: state,
            budget: ContextBudget(total: 4096, reservedForOutput: 768, maxTools: 6)
        )
        XCTAssertTrue(
            assembled.tools.contains { $0.name == "weather_summary" },
            "the only tool that could answer was trimmed away: \(assembled.tools.map(\.name))"
        )
    }

    /// The end-to-end case this was all for: six MCP-sized schemas on a
    /// 4,096-token window. Uncompacted, one of them alone busts the
    /// share and the model gets a single tool. Compacted, several fit.
    func testCompactionLetsSeveralMCPToolsThrough() async throws {
        let pinned = Self.tool(named: "load_skill", descriptionLength: 40)
        let weather = (0 ..< 6).map { Self.mcpSizedTool(named: "weather_mcp__tool_\($0)") }
        let assembler = DefaultContextAssembler(
            pinnedToolNames: ["load_skill"],
            unrankedFillLimit: 0
        )
        var state = AgentState()
        state.messages = [.user("weather forecast for dublin")]

        let budget = ContextBudget(total: 4096, reservedForOutput: 768, maxTools: 6)
        let assembled = await assembler.assemble(
            systemPrompt: "You are helpful.",
            tools: [pinned] + weather,
            state: state,
            budget: budget
        )

        let sent = assembled.tools.filter { $0.name.hasPrefix("weather_mcp__") }
        XCTAssertGreaterThan(
            sent.count,
            1,
            "compaction bought nothing: \(assembled.tools.map(\.name))"
        )
        let counter = HeuristicTokenCounter()
        let cost = assembled.tools.reduce(0) { $0 + counter.count(tool: $1.definition) }
        XCTAssertLessThanOrEqual(cost, budget.toolTokenLimit)
    }

    /// Sized and shaped like a published MCP schema: a paragraph of
    /// description and several documented parameters.
    private static func mcpSizedTool(named name: String) -> AnyTool {
        AnyTool(
            definition: ToolDefinition(
                name: name,
                description: String(
                    repeating: "Retrieve weather forecast conditions for a location, "
                        + "including temperature, precipitation, wind, humidity and alerts. ",
                    count: 20
                ),
                inputSchema: .object(
                    properties: [
                        "location": .string(
                            description: String(repeating: "City name or coordinates. ", count: 24),
                            enumValues: nil
                        ),
                        "units": .string(
                            description: String(repeating: "Measurement system to use. ", count: 24),
                            enumValues: ["metric", "imperial"]
                        ),
                        "detail": .string(
                            description: String(repeating: "How much detail to return. ", count: 24),
                            enumValues: nil
                        ),
                    ],
                    required: ["location"]
                )
            ),
            invoke: { _, _ in .object([:]) }
        )
    }

    /// Small tools are unaffected — the ceiling must not become a cap
    /// that starves ordinary surfaces.
    func testSmallToolSurfacesAreNotTrimmed() async throws {
        let tools = (0 ..< 5).map { Self.tool(named: "t\($0)", descriptionLength: 40) }
        let assembler = DefaultContextAssembler(unrankedFillLimit: 0)
        let request = await assembler.assemble(
            systemPrompt: "You are helpful.",
            tools: tools,
            state: Self.state(query: "t1 t2 t3"),
            budget: ContextBudget(total: 8192, reservedForOutput: 768, maxTools: 12)
        )
        XCTAssertEqual(request.tools.count, 5)
    }

    // MARK: Private

    private static func state(query: String) -> AgentState {
        var state = AgentState()
        state.messages = [.user(query)]
        return state
    }

    private static func tool(named name: String, descriptionLength: Int) -> AnyTool {
        AnyTool(
            definition: ToolDefinition(
                name: name,
                description: String(repeating: "weather forecast data ", count: descriptionLength / 22),
                inputSchema: .object(
                    properties: ["location": .string(description: "Place name")],
                    required: ["location"]
                )
            ),
            invoke: { _, _ in .object([:]) }
        )
    }
}
