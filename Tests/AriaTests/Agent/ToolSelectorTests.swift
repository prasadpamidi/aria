import Foundation
import XCTest
@testable import Aria

// MARK: - LexicalToolSelectorTests

final class LexicalToolSelectorTests: XCTestCase {
    // MARK: - Tokenisation

    /// Tool names are identifiers, so a whitespace-only tokenizer would
    /// treat `log_meal` as a single opaque term and match essentially
    /// nothing. Splitting identifiers into words is what makes lexical
    /// ranking viable at all here.
    func testTokenizerSplitsIdentifierConventions() {
        XCTAssertEqual(LexicalToolSelector.tokenize("log_meal"), ["log", "meal"])
        XCTAssertEqual(LexicalToolSelector.tokenize("getWeatherToday"), ["get", "weather", "today"])
        XCTAssertEqual(LexicalToolSelector.tokenize("shopping-list"), ["shopping", "list"])
    }

    /// Single characters carry no signal and inflate every score.
    func testTokenizerDropsSingleCharacterTerms() {
        XCTAssertEqual(LexicalToolSelector.tokenize("a b log"), ["log"])
    }

    // MARK: - Ranking

    func testRanksMatchingToolFirst() async {
        let selector = LexicalToolSelector()
        let result = await selector.select(
            from: [
                Self.definition("convert_currency", "Convert between currencies."),
                Self.definition("log_meal", "Record a meal the user ate."),
            ],
            query: "log the meal I ate",
            limit: 1
        )
        XCTAssertEqual(result.map(\.name), ["log_meal"])
    }

    /// A term shared by every tool carries no discriminating power, so
    /// IDF must damp it. Without this, boilerplate phrasing in
    /// descriptions dominates and ranking degenerates to noise.
    func testCommonTermsDoNotDominateRanking() async {
        let selector = LexicalToolSelector()
        let tools = [
            Self.definition("alpha", "Returns the result for a given value."),
            Self.definition("beta", "Returns the result for a given value."),
            Self.definition("weather_report", "Returns the result for a given weather value."),
        ]
        let result = await selector.select(from: tools, query: "weather", limit: 1)
        XCTAssertEqual(result.map(\.name), ["weather_report"])
    }

    func testReturnsNothingWhenNothingIsRelevant() async {
        let selector = LexicalToolSelector()
        let result = await selector.select(
            from: [Self.definition("rotate_image", "Rotate an image by degrees.")],
            query: "how is it going",
            limit: 5
        )
        XCTAssertTrue(
            result.isEmpty,
            "A greeting matches no tool; padding the list would reintroduce the cost we're removing"
        )
    }

    func testRespectsLimit() async {
        let selector = LexicalToolSelector()
        let tools = (0..<10).map { Self.definition("weather_\($0)", "Weather forecast data.") }
        let result = await selector.select(from: tools, query: "weather forecast", limit: 3)
        XCTAssertEqual(result.count, 3)
    }

    func testEmptyQueryReturnsNothing() async {
        let selector = LexicalToolSelector()
        let result = await selector.select(
            from: [Self.definition("log_meal", "Record a meal.")],
            query: "",
            limit: 5
        )
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Helpers

    private static func definition(_ name: String, _ description: String) -> ToolDefinition {
        ToolDefinition(
            name: name,
            description: description,
            inputSchema: .object(properties: [:], required: [])
        )
    }
}

// MARK: - HeuristicTokenCounterTests

final class HeuristicTokenCounterTests: XCTestCase {
    func testEmptyTextCostsNothing() {
        XCTAssertEqual(HeuristicTokenCounter().count(text: ""), 0)
    }

    /// Schemas are measured with a denser ratio than prose, because
    /// JSON punctuation tokenizes worse than words. Measuring a tool
    /// with a prose ratio is how a large tool surface ends up costing
    /// materially more than the budget believed.
    func testToolCostExceedsNaiveProseEstimateOfItsText() {
        let counter = HeuristicTokenCounter()
        let tool = ToolDefinition(
            name: "log_meal",
            description: "Record a meal the user ate today.",
            inputSchema: .object(
                properties: [
                    "name": .string(description: "Dish name"),
                    "calories": .integer(description: "Energy in kcal"),
                ],
                required: ["name"]
            )
        )
        let proseOnly = counter.count(text: "log_meal") + counter.count(text: tool.description)
        XCTAssertGreaterThan(counter.count(tool: tool), proseOnly)
    }

    func testGuidanceIsChargedToTheTool() {
        let counter = HeuristicTokenCounter()
        let schema = JSONSchema.object(properties: [:], required: [])
        let bare = ToolDefinition(name: "t", description: "d", inputSchema: schema)
        let guided = ToolDefinition(
            name: "t",
            description: "d",
            inputSchema: schema,
            promptGuidance: "Use this when the user reports a meal."
        )
        XCTAssertGreaterThan(counter.count(tool: guided), counter.count(tool: bare))
    }
}

// MARK: - ContextBudgetTests

final class ContextBudgetTests: XCTestCase {
    func testAvailableSubtractsOutputReserve() {
        let budget = ContextBudget(total: 4096, reservedForOutput: 512)
        XCTAssertEqual(budget.available, 3584)
    }

    /// A reserve larger than the window would otherwise produce a
    /// negative allowance and trim everything, including the turn the
    /// model has to answer.
    func testOutputReserveCannotExceedTotal() {
        let budget = ContextBudget(total: 100, reservedForOutput: 500)
        XCTAssertEqual(budget.available, 0)
        XCTAssertEqual(budget.reservedForOutput, 100)
    }

    func testNegativeInputsAreClamped() {
        let budget = ContextBudget(total: -10, reservedForOutput: -5, maxTools: -3)
        XCTAssertEqual(budget.total, 0)
        XCTAssertEqual(budget.reservedForOutput, 0)
        XCTAssertEqual(budget.maxTools, 0)
    }
}
