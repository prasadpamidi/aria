import Aria
import Foundation

// MARK: - ToolSelectionFixtures

/// A realistic tool surface and the queries that have actually failed
/// against it.
///
/// Shared across test targets so every ranker — lexical, Apple's
/// contextual embedding, an MLX encoder — is measured on the *same*
/// corpus. A comparison where each candidate brings its own fixtures
/// measures the fixtures.
///
/// Cases marked FIELD came from real sessions, with the tool that
/// would have answered. The rest guard properties worth keeping.
public enum ToolSelectionFixtures {
    /// A device's actual surface: Niora, a second MCP server, and
    /// the built-ins.
    public static let corpus: [ToolDefinition] = [
        ToolSelectionFixtures.tool(
            "niora__get_fasting_status",
            "Whether the user is fasting now, and progress toward their target if so."
        ),
        ToolSelectionFixtures.tool("niora__start_fast", "Start a fast for the user."),
        ToolSelectionFixtures.tool("niora__end_fast", "End the user's current fast."),
        ToolSelectionFixtures.tool("niora__get_fasting_stats", "Fasting history and streaks over recent weeks."),
        ToolSelectionFixtures.tool(
            "niora__get_weight_trend",
            "The user's weight trend over time, with the latest recorded value."
        ),
        ToolSelectionFixtures.tool("niora__log_weight", "Record a weight measurement for the user in kilograms."),
        ToolSelectionFixtures.tool("niora__log_meal", "Record a meal the user ate, with its nutrition."),
        ToolSelectionFixtures.tool("niora__list_meals", "Meals the user has eaten on a given day."),
        ToolSelectionFixtures.tool(
            "niora__get_daily_nutrition",
            "Calories and macros consumed against the user's goals."
        ),
        ToolSelectionFixtures.tool(
            "niora__search_recipes",
            "Search the recipe library by ingredient, cuisine or meal type."
        ),
        ToolSelectionFixtures.tool("niora__get_recipe", "Full ingredients and steps for one saved recipe."),
        ToolSelectionFixtures.tool("niora__save_recipe", "Save a recipe to the user's library."),
        ToolSelectionFixtures.tool(
            "niora__get_shopping_list",
            "The shopping list for a week, generated from the meal plan."
        ),
        ToolSelectionFixtures.tool("niora__add_shopping_item", "Add an item to the user's shopping list."),
        ToolSelectionFixtures.tool(
            "niora__get_readiness",
            "Daily readiness score with the sleep, HRV and soreness signals behind it."
        ),
        ToolSelectionFixtures.tool("niora__get_workout", "Details of one workout, including its exercises and sets."),
        ToolSelectionFixtures.tool("niora__list_workouts", "Workouts the user has completed, most recent first."),
        ToolSelectionFixtures.tool(
            "niora__generate_workout",
            "Build a new workout for the user from their program and equipment."
        ),
        ToolSelectionFixtures.tool("niora__log_water", "Log a water intake entry in millilitres."),
        ToolSelectionFixtures.tool(
            "niora__get_hydration_today",
            "How much water the user has drunk against their target."
        ),
        ToolSelectionFixtures.tool(
            "niora__get_profile",
            "The user's profile: display name, units, goals, dietary preferences."
        ),
        ToolSelectionFixtures.tool("niora__get_daily_briefing", "The user's full context for today in one call."),
        ToolSelectionFixtures.tool("simplemcp__get_weather", "Get the current weather for a city."),
        ToolSelectionFixtures.tool("simplemcp__get_forecast", "Get the multi-day weather forecast for a city."),
        ToolSelectionFixtures.tool("current_time", "Get the current date and time in the user's timezone."),
        ToolSelectionFixtures.tool("http_request", "Perform an HTTP request to a URL and return the response body."),
        ToolSelectionFixtures.tool(
            "remember_fact",
            "Save a durable, first-person fact about the user that should persist."
        ),
        ToolSelectionFixtures.tool("load_skill", "Load a named skill's instructions on demand."),
        ToolSelectionFixtures.tool("run_quick_add_to_groceries_remix", "Quickly add an item to the groceries list."),
        ToolSelectionFixtures.tool("open_url", "Open a URL in the browser."),
    ]

    public static let cases: [ToolSelectionCase] = [
        // FIELD — ranked current_time and get_weather on "current",
        // offered nothing about weight, and the model flailed into
        // three unrelated skill loads before the turn died.
        ToolSelectionCase(
            query: "What's my current weight?",
            expected: ["niora__get_weight_trend"],
            misleading: ["current_time", "simplemcp__get_weather"],
            note: "FIELD 2026-08-07: recency adjective decided the match"
        ),
        // FIELD — a twenty-tool surface reduced to one match on the
        // word "quick".
        ToolSelectionCase(
            query: "give me a quick recipe idea",
            expected: ["niora__search_recipes", "niora__get_recipe"],
            misleading: ["run_quick_add_to_groceries_remix"],
            note: "FIELD: generic adjective decided the match"
        ),
        // FIELD — worked, and must keep working.
        ToolSelectionCase(
            query: "Check my fasting status",
            expected: ["niora__get_fasting_status"],
            misleading: ["remember_fact"],
            note: "FIELD: regression guard"
        ),
        // The gap no stopword list can close: no shared term with
        // "Record a meal the user ate".
        ToolSelectionCase(
            query: "what did I eat today?",
            expected: ["niora__list_meals", "niora__get_daily_nutrition"],
            note: "Vocabulary mismatch — lexical ranking cannot connect these"
        ),
        ToolSelectionCase(
            query: "how much water have I had?",
            expected: ["niora__get_hydration_today"],
            note: "Paraphrase of the description"
        ),
        ToolSelectionCase(
            query: "am I recovered enough to train hard today?",
            expected: ["niora__get_readiness"],
            misleading: ["current_time"],
            note: "Intent stated without any of the description's terms"
        ),
        ToolSelectionCase(
            query: "what is the current time now",
            expected: ["current_time"],
            note: "Recency words as the subject must still reach a clock"
        ),
        ToolSelectionCase(
            query: "what's the weather like in Tokyo",
            expected: ["simplemcp__get_weather"],
            note: "Unambiguous — a floor case"
        ),
        ToolSelectionCase(
            query: "I weighed 82 kg this morning",
            expected: ["niora__log_weight"],
            misleading: ["niora__get_weight_trend"],
            note: "Writing vs reading the same subject"
        ),
        ToolSelectionCase(
            query: "add oat milk to my shopping list",
            expected: ["niora__add_shopping_item"],
            note: "Unambiguous — a floor case"
        ),
        ToolSelectionCase(
            query: "remember that I'm vegetarian",
            expected: ["remember_fact"],
            note: "Regression guard for the memory path"
        ),
        ToolSelectionCase(
            query: "what did I lift last week?",
            expected: ["niora__list_workouts"],
            note: "Domain synonym: lift/workout"
        ),
    ]

    public static var eval: ToolSelectionEval {
        ToolSelectionEval(corpus: self.corpus, cases: self.cases)
    }

    public static func tool(_ name: String, _ description: String) -> ToolDefinition {
        ToolDefinition(
            name: name,
            description: description,
            inputSchema: .object(properties: [:], required: [])
        )
    }
}
