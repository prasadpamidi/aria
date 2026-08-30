@testable import Aria
import AriaTesting
import XCTest

/// Does the token estimate describe the request that actually ships?
///
/// Nothing checked this until now, and every budget failure worth
/// debugging turned out to be the gap between the two: a turn priced at
/// 1,366 tokens refused at 5,362, with the budget reporting itself
/// satisfied afterwards.
///
/// The assertions are one-sided on purpose. Over-estimating wastes
/// budget and sends fewer tools; under-estimating overflows the window
/// and loses the whole turn.
final class ContextAuditTests: XCTestCase {
    // MARK: - The systemic risk

    /// A realistic MCP schema, costed and rendered.
    func testMCPSizedToolIsNotWildlyUnderestimated() {
        let report = ContextAudit().audit(tool: Self.mcpTool)
        XCTAssertLessThan(
            report.underestimateFactor,
            1.5,
            "estimate is optimistic: \(report.summary())"
        )
    }

    /// The specific error that priced a JSON blob as prose. A tool
    /// whose description *contains* its schema — how the MCP bridge
    /// presents them to FoundationModels — is the case that broke.
    func testSchemaInsideADescriptionIsNotPricedAsProse() {
        let inlined = ToolDefinition(
            name: "weather_mcp__get_weather_summary",
            description: """
            Get a weather summary.

            Input schema:
            \(Self.schemaJSON)
            """,
            inputSchema: Self.mcpTool.inputSchema
        )
        let report = ContextAudit().audit(tool: inlined)
        XCTAssertLessThan(
            report.underestimateFactor,
            1.5,
            "description-embedded schema underpriced: \(report.summary())"
        )
    }

    /// Six of them, the surface that produced the field failure.
    func testARealisticToolSurfaceIsNotUnderestimated() async {
        let tools = (0 ..< 6).map { index in
            AnyTool(
                definition: ToolDefinition(
                    name: "weather_mcp__tool_\(index)",
                    description: Self.mcpTool.description,
                    inputSchema: Self.mcpTool.inputSchema
                ),
                invoke: { _, _ in .object([:]) }
            )
        }
        var state = AgentState()
        state.messages = [.user("what is the weather in dublin")]
        let assembled = await DefaultContextAssembler(unrankedFillLimit: 0).assemble(
            systemPrompt: "You are a concise, helpful assistant.",
            tools: tools,
            state: state,
            budget: ContextBudget(total: 8192, reservedForOutput: 768, maxTools: 6)
        )
        let report = ContextAudit().audit(assembled)
        XCTAssertLessThan(
            report.underestimateFactor,
            1.5,
            "assembled request underpriced: \(report.summary())"
        )
    }

    // MARK: - Sanity

    /// Prose should not be *over*-estimated into uselessness either —
    /// a counter that doubles everything would pass the checks above
    /// while sending a third of the tools it could.
    func testProseIsNotWildlyOverestimated() {
        let chatty = ToolDefinition(
            name: "note",
            description: String(repeating: "Write a short note for later. ", count: 20),
            inputSchema: .object(
                properties: ["text": .string(description: "The note body.")],
                required: ["text"]
            )
        )
        let report = ContextAudit().audit(tool: chatty)
        XCTAssertGreaterThan(
            report.underestimateFactor,
            0.4,
            "estimate is wasteful: \(report.summary())"
        )
    }

    /// A tool-calling turn costs its call, not its (empty) text. This
    /// is the message most likely to overflow and the easiest to price
    /// at nearly zero.
    func testToolCallingTurnIsNotPricedAtZero() {
        let counter = HeuristicTokenCounter()
        let message = Message.assistant("", toolCalls: [
            ToolCall(
                id: "1",
                name: "weather_mcp__get_weather_summary",
                arguments: .object([
                    "city_name": .string("Dublin"),
                    "days": .integer(7),
                    "detail": .string("summary"),
                ])
            ),
        ])
        XCTAssertGreaterThan(counter.count(message: message), 10)
    }

    // MARK: Private

    private static let schemaJSON = """
    {"type":"object","properties":{"city_name":{"type":"string","description":"City name, \
    postal code, or coordinates."},"days":{"type":"integer","description":"How many days of \
    forecast, 1 to 16."},"units":{"type":"string","enum":["metric","imperial"],"description":\
    "Measurement system."},"detail":{"type":"string","description":"summary, standard or full."}},\
    "required":["city_name"]}
    """

    private static let mcpTool = ToolDefinition(
        name: "weather_mcp__get_weather_summary",
        description: """
        Retrieve a plain-language weather summary for a location, including current \
        conditions, today's forecast, precipitation probability, wind, humidity, UV index \
        and any active severe weather alerts. Accepts a city name or coordinates.
        """,
        inputSchema: .object(
            properties: [
                "city_name": .string(description: "City name, postal code, or coordinates."),
                "days": .integer(description: "How many days of forecast, 1 to 16."),
                "units": .string(
                    description: "Measurement system.",
                    enumValues: ["metric", "imperial"]
                ),
                "detail": .string(description: "summary, standard or full."),
            ],
            required: ["city_name"]
        )
    )
}
