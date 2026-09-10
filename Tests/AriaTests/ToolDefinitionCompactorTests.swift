@testable import Aria
import XCTest

/// A published MCP tool schema is routinely a thousand tokens — a
/// paragraph of description plus a dozen documented parameters. On a
/// 4,096-token window that is a quarter of everything, for one tool
/// the model may not call.
///
/// The constraint these pin: compaction removes *guidance*, never
/// *capability*. A call the model could make before must still
/// validate after, because a tool it calls with worse arguments is
/// recoverable and a tool whose arguments no longer validate is not.
final class ToolDefinitionCompactorTests: XCTestCase {
    // MARK: - Safety

    /// The one outcome this must never produce.
    func testRequiredPropertiesSurviveEveryLevel() {
        for level in ToolCompaction.allCases {
            let compacted = ToolDefinitionCompactor.apply(level, to: Self.weatherTool)
            guard case let .object(properties, required, _, _) = compacted.inputSchema else {
                return XCTFail("schema shape changed at \(level)")
            }
            XCTAssertEqual(required, ["location"], "required list changed at \(level)")
            XCTAssertNotNil(properties["location"], "required property dropped at \(level)")
        }
    }

    /// Enum values are the set of legal inputs, not documentation. A
    /// model guessing outside them produces a call that fails.
    func testEnumValuesSurviveEveryLevel() {
        for level in ToolCompaction.allCases {
            let compacted = ToolDefinitionCompactor.apply(level, to: Self.weatherTool)
            guard case let .object(properties, _, _, _) = compacted.inputSchema,
                  case let .string(_, enumValues) = properties["units"] ?? .null else {
                // `units` is optional and legitimately gone at the last
                // level; its absence is not a failure.
                XCTAssertEqual(level, .requiredOnly, "units vanished early at \(level)")
                continue
            }
            XCTAssertEqual(enumValues, ["metric", "imperial"], "enum lost at \(level)")
        }
    }

    func testNameIsNeverChanged() {
        for level in ToolCompaction.allCases {
            XCTAssertEqual(
                ToolDefinitionCompactor.apply(level, to: Self.weatherTool).name,
                "weather_mcp__get_weather_summary"
            )
        }
    }

    // MARK: - Effect

    /// Each level must actually be cheaper, or it is not worth the
    /// capability it costs.
    func testEachLevelIsStrictlyCheaper() {
        let counter = HeuristicTokenCounter()
        let costs = ToolCompaction.allCases.map {
            counter.count(tool: ToolDefinitionCompactor.apply($0, to: Self.weatherTool))
        }
        for (index, cost) in costs.enumerated().dropFirst() {
            XCTAssertLessThan(cost, costs[index - 1], "level \(index) did not shrink anything")
        }
        // The headline: the thing that made this necessary.
        XCTAssertLessThan(
            Double(costs.last ?? 0),
            Double(costs[0]) * 0.5,
            "full compaction saved less than half: \(costs)"
        )
    }

    /// Stops at the lightest level that fits rather than flattening
    /// everything — capability is only given up when it buys something.
    func testStopsAtTheLightestLevelThatFits() {
        let counter = HeuristicTokenCounter()
        let full = counter.count(tool: Self.weatherTool)
        let (_, applied) = ToolDefinitionCompactor.compact(
            Self.weatherTool,
            toFit: full,
            counter: counter
        )
        XCTAssertEqual(applied, .none, "compacted a tool that already fit")
    }

    /// A description with no sentence break still shrinks.
    func testUnpunctuatedDescriptionIsCapped() {
        let rambling = ToolDefinition(
            name: "t",
            description: String(repeating: "words and more words ", count: 60),
            inputSchema: .object(properties: [:], required: [])
        )
        let compacted = ToolDefinitionCompactor.apply(.shortDescription, to: rambling)
        XCTAssertLessThan(compacted.description.count, rambling.description.count / 2)
    }

    // MARK: Private

    /// Shaped like the real thing that caused the problem.
    private static let weatherTool = ToolDefinition(
        name: "weather_mcp__get_weather_summary",
        description: """
        Retrieve a plain-language weather summary for a location. Includes current \
        conditions, today's forecast, precipitation probability, wind, humidity, UV \
        index and any active severe weather alerts. Accepts a city name or \
        coordinates. Data comes from NOAA and Open-Meteo and is cached for fifteen \
        minutes. See also get_forecast for multi-day output.
        """,
        inputSchema: .object(
            properties: [
                "location": .string(
                    description: "City name, postal code, or 'lat,lon' coordinates. Required.",
                    enumValues: nil
                ),
                "units": .string(
                    description: "Measurement system for temperature, wind and precipitation.",
                    enumValues: ["metric", "imperial"]
                ),
                "detail": .string(
                    description: "How much to return: summary is one paragraph, full includes hourly breakdowns.",
                    enumValues: ["summary", "standard", "full"]
                ),
                "include_alerts": .boolean(
                    description: "Whether to include active severe weather alerts in the response."
                ),
            ],
            required: ["location"],
            description: "Arguments for the weather summary request."
        )
    )
}
