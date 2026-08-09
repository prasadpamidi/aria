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
