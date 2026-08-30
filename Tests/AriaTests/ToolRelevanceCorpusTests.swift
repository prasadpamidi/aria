@testable import Aria
import XCTest

/// Queries that should send *no* tool, and queries that should.
///
/// The eval corpus measures whether the right tool is offered. It has
/// almost nothing on the opposite failure — a tool offered when none is
/// relevant — and that is the one users notice. Asked "What's the
/// tracking number?", the ranker offered `calculator`, the model called
/// it with `(4.45 - 4.45) / 16` scavenged from a fasting summary, and
/// the reply was `0`.
///
/// The two known failures are asserted as *expected* failures rather
/// than deleted or quietly passed. They are real, they are not fixed,
/// and a corpus that hides them is worth less than one that states
/// them.
final class ToolRelevanceCorpusTests: XCTestCase {
    // MARK: - Nothing should rank

    /// Conversation, gratitude, and questions about the conversation
    /// itself. These already work.
    func testConversationalTurnsRankNothing() async {
        for query in [
            "How are you?",
            "Thanks!",
            "What did we talk about earlier?",
            "Explain quantum computing",
        ] {
            let ranked = await LexicalToolSelector().select(
                from: Self.surface,
                query: query,
                limit: 6
            )
            XCTAssertTrue(ranked.isEmpty, "\"\(query)\" offered \(ranked.map(\.name))")
        }
    }

    /// A single common word matching a single tool.
    ///
    /// "number" appears in `calculator`, `uuid` and `unit_converter`;
    /// "fact" appears in `remember_fact`. Neither query is *about*
    /// those tools, and one term of overlap out of two is not
    /// responsiveness — but nothing in the ranker says so yet.
    ///
    /// The obvious fix — require two matched terms — breaks "remind me
    /// to buy milk", where one matched term is the whole intent. That
    /// is why this is recorded rather than patched: the rule needs
    /// measuring against more than the four cases that motivated it.
    func testSingleCommonWordShouldNotRankATool() async {
        XCTExpectFailure("known gap: no relevance floor on a single weak term")
        for query in ["What's the tracking number?", "Tell me a fun fact"] {
            let ranked = await LexicalToolSelector().select(
                from: Self.surface,
                query: query,
                limit: 6
            )
            XCTAssertTrue(ranked.isEmpty, "\"\(query)\" offered \(ranked.map(\.name))")
        }
    }

    // MARK: - Something should rank

    /// The other side of the trade. Any relevance floor added later has
    /// to keep every one of these.
    func testRealRequestsStillRankTheRightTool() async {
        let expectations = [
            "Get me weather summary": "weather_mcp__get_weather_summary",
            "How am I doing with fasting today?": "niora__get_fasting_status",
            "log 500ml of water": "niora__log_water",
            "what time is it": "current_time",
        ]
        for (query, expected) in expectations {
            let ranked = await LexicalToolSelector().select(
                from: Self.surface,
                query: query,
                limit: 6
            )
            XCTAssertEqual(ranked.first?.name, expected, "\"\(query)\" ranked \(ranked.map(\.name))")
        }
    }

    // MARK: Private

    /// The surface from a real device: built-ins, a weather MCP server,
    /// Niora, and two workflow remixes.
    private static let surface: [ToolDefinition] = [
        ("current_time", "Get the current date and time."),
        ("remember_fact", "Save a durable fact about the user."),
        ("http_request", "Fetch a URL over HTTP."),
        ("calculator", "Evaluate an arithmetic expression and return the resulting number."),
        ("json_path", "Extract values from JSON with a path expression."),
        ("regex", "Match or replace text with a regular expression."),
        ("uuid", "Generate a unique identifier number."),
        ("unit_converter", "Convert a number between units of measurement."),
        ("random_picker", "Pick a random item from a list."),
        ("date_math", "Add or subtract intervals from a date."),
        ("weather_mcp__get_weather_summary", "Get a plain-language weather summary for a location."),
        ("weather_mcp__get_forecast", "Get a multi-day weather forecast for a location."),
        ("weather_mcp__get_current_conditions", "Get current weather conditions for a location."),
        ("weather_mcp__get_alerts", "Get active severe weather alerts for a location."),
        ("niora__get_fasting_status", "Whether the user is fasting now, and progress toward target."),
        ("niora__start_fast", "Begin a new fast for the user."),
        ("niora__end_fast", "End the user's current fast."),
        ("niora__log_water", "Log a water intake entry in millilitres."),
        ("niora__get_hydration_today", "How much water the user has drunk today."),
        ("niora__get_profile", "The user's profile: display name, goals, dietary preferences."),
    ].map {
        ToolDefinition(
            name: $0.0,
            description: $0.1,
            inputSchema: .object(properties: [:], required: [])
        )
    }
}
