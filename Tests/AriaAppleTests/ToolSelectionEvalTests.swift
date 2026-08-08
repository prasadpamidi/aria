#if canImport(NaturalLanguage) && (os(iOS) || os(macOS))

    import Aria
    import AriaApple
    import AriaTesting
    import XCTest

    // MARK: - ToolSelectionEvalTests

    /// Measures tool selection instead of guessing at it.
    ///
    /// Every knob in this area was set by intuition and corrected after
    /// a field failure: a cap of five tools, a 40% share ceiling, and a
    /// stopword list that grew twice for the same root cause. Adding
    /// words to that list is hand-encoding English word-frequency one
    /// incident at a time, and there is no version of it that is
    /// finished.
    ///
    /// The corpus below mirrors a real device — a Niora MCP server, a
    /// second MCP server, and the built-in tools — and the cases marked
    /// FIELD are queries that actually failed, with the answer that was
    /// actually wanted.
    final class ToolSelectionEvalTests: XCTestCase {
        // MARK: - The comparison

        /// Prints every ranker over the same corpus.
        ///
        /// The result contradicted the hypothesis that motivated this
        /// harness. Embedding ranking was expected to replace lexical
        /// and retire the stopword list; measured, it lost on every
        /// metric. `NLEmbedding` is a 2019-era sentence embedding and
        /// puts everything user-shaped near everything else — it ranked
        /// `load_skill` above a weight tool, and missed a fasting query
        /// that lexical answers first try.
        ///
        /// Recorded rather than deleted, because a negative result that
        /// nobody wrote down gets re-proposed every few months.
        func testRankerComparisonOnTheFieldCorpus() async throws {
            let embedder = try XCTUnwrap(
                NLEmbeddingEmbedder(),
                "No sentence embedding for English on this OS"
            )
            let eval = ToolSelectionEval(corpus: Self.corpus, cases: Self.cases)

            let lexical = await eval.run(LexicalToolSelector(), label: "lexical")
            let noStopWords = await eval.run(
                LexicalToolSelector(stopWords: []),
                label: "lexical/no-stopwords"
            )
            let embedding = await eval.run(
                EmbeddingToolSelector(embedder: embedder, fallback: nil),
                label: "embedding"
            )
            let fused = await eval.run(
                FusedToolSelector(selectors: [
                    LexicalToolSelector(),
                    EmbeddingToolSelector(embedder: embedder, fallback: nil),
                ]),
                label: "fused"
            )

            for report in [lexical, noStopWords, embedding, fused] {
                print("\n" + report.summary())
            }
            print("")

            XCTAssertGreaterThan(lexical.hitRate, 0.5, "The shipped default must clear a floor")
        }

        /// Does the stopword list earn its maintenance?
        ///
        /// It was grown twice on intuition, and intuition is what this
        /// harness exists to replace. Measured: it is the only thing
        /// standing between the ranker and a generic adjective deciding
        /// the match. Removing it puts `run_quick_add_to_groceries_remix`
        /// first for a recipe question and a clock first for a weight
        /// question — the two original field failures, reproduced.
        func testStopWordsPreventGenericTermsFromDecidingTheMatch() async throws {
            let junkTermCases = Self.cases.filter { !$0.misleading.isEmpty }
            let eval = ToolSelectionEval(corpus: Self.corpus, cases: junkTermCases)

            let with = await eval.run(LexicalToolSelector(), label: "with stopwords")
            let without = await eval.run(
                LexicalToolSelector(stopWords: []),
                label: "without stopwords"
            )

            print("\n" + with.summary())
            print("\n" + without.summary() + "\n")

            XCTAssertEqual(with.misleadRate, 0, "Stopwords must hold the field cases")
            XCTAssertGreaterThan(
                without.misleadRate,
                with.misleadRate,
                "If removing the list changes nothing, it is maintenance with no purpose"
            )
        }

        // MARK: - Properties the assembler depends on

        /// `DefaultContextAssembler` reads an empty ranking as "no
        /// signal" and falls back to sending everything that fits.
        /// Cosine similarity is never exactly zero, so without a floor
        /// this selector would return its whole input and silently
        /// disable that fallback.
        func testUnrelatedQueryRanksNothing() async throws {
            let embedder = try XCTUnwrap(NLEmbeddingEmbedder())
            let selector = EmbeddingToolSelector(
                embedder: embedder,
                minimumSimilarity: 0.9,
                fallback: nil
            )

            let selected = await selector.select(
                from: Self.corpus,
                query: "zzzz qqqq",
                limit: 5
            )
            XCTAssertTrue(selected.isEmpty, "A floor must be able to reject everything")
        }

        /// Embedding is a model-dependent step in a path that must not
        /// lose the ability to rank at all.
        func testFallbackRanksWhenNothingClearsTheFloor() async throws {
            let embedder = try XCTUnwrap(NLEmbeddingEmbedder())
            let selector = EmbeddingToolSelector(
                embedder: embedder,
                minimumSimilarity: 0.99,
                fallback: LexicalToolSelector()
            )

            let selected = await selector.select(
                from: Self.corpus,
                query: "log my meal",
                limit: 3
            )
            XCTAssertFalse(selected.isEmpty, "The fallback must still rank")
        }

        /// Unanimous silence must stay silence — fusion must not invent
        /// a ranking the assembler will read as confidence.
        func testFusionOfSilentRankersRanksNothing() async {
            let fused = FusedToolSelector(selectors: [
                LexicalToolSelector(),
                LexicalToolSelector(),
            ])
            let selected = await fused.select(
                from: Self.corpus,
                query: "zzzz qqqq",
                limit: 5
            )
            XCTAssertTrue(selected.isEmpty)
        }

        // MARK: - Fixtures

        /// A device's actual surface: Niora, a second MCP server, and
        /// the built-ins.
        static let corpus: [ToolDefinition] = [
            ToolSelectionEvalTests.tool("niora__get_fasting_status", "Whether the user is fasting now, and progress toward their target if so."),
            ToolSelectionEvalTests.tool("niora__start_fast", "Start a fast for the user."),
            ToolSelectionEvalTests.tool("niora__end_fast", "End the user's current fast."),
            ToolSelectionEvalTests.tool("niora__get_fasting_stats", "Fasting history and streaks over recent weeks."),
            ToolSelectionEvalTests.tool("niora__get_weight_trend", "The user's weight trend over time, with the latest recorded value."),
            ToolSelectionEvalTests.tool("niora__log_weight", "Record a weight measurement for the user in kilograms."),
            ToolSelectionEvalTests.tool("niora__log_meal", "Record a meal the user ate, with its nutrition."),
            ToolSelectionEvalTests.tool("niora__list_meals", "Meals the user has eaten on a given day."),
            ToolSelectionEvalTests.tool("niora__get_daily_nutrition", "Calories and macros consumed against the user's goals."),
            ToolSelectionEvalTests.tool("niora__search_recipes", "Search the recipe library by ingredient, cuisine or meal type."),
            ToolSelectionEvalTests.tool("niora__get_recipe", "Full ingredients and steps for one saved recipe."),
            ToolSelectionEvalTests.tool("niora__save_recipe", "Save a recipe to the user's library."),
            ToolSelectionEvalTests.tool("niora__get_shopping_list", "The shopping list for a week, generated from the meal plan."),
            ToolSelectionEvalTests.tool("niora__add_shopping_item", "Add an item to the user's shopping list."),
            ToolSelectionEvalTests.tool("niora__get_readiness", "Daily readiness score with the sleep, HRV and soreness signals behind it."),
            ToolSelectionEvalTests.tool("niora__get_workout", "Details of one workout, including its exercises and sets."),
            ToolSelectionEvalTests.tool("niora__list_workouts", "Workouts the user has completed, most recent first."),
            ToolSelectionEvalTests.tool("niora__generate_workout", "Build a new workout for the user from their program and equipment."),
            ToolSelectionEvalTests.tool("niora__log_water", "Log a water intake entry in millilitres."),
            ToolSelectionEvalTests.tool("niora__get_hydration_today", "How much water the user has drunk against their target."),
            ToolSelectionEvalTests.tool("niora__get_profile", "The user's profile: display name, units, goals, dietary preferences."),
            ToolSelectionEvalTests.tool("niora__get_daily_briefing", "The user's full context for today in one call."),
            ToolSelectionEvalTests.tool("simplemcp__get_weather", "Get the current weather for a city."),
            ToolSelectionEvalTests.tool("simplemcp__get_forecast", "Get the multi-day weather forecast for a city."),
            ToolSelectionEvalTests.tool("current_time", "Get the current date and time in the user's timezone."),
            ToolSelectionEvalTests.tool("http_request", "Perform an HTTP request to a URL and return the response body."),
            ToolSelectionEvalTests.tool("remember_fact", "Save a durable, first-person fact about the user that should persist."),
            ToolSelectionEvalTests.tool("load_skill", "Load a named skill's instructions on demand."),
            ToolSelectionEvalTests.tool("run_quick_add_to_groceries_remix", "Quickly add an item to the groceries list."),
            ToolSelectionEvalTests.tool("open_url", "Open a URL in the browser."),
        ]

        static let cases: [ToolSelectionCase] = [
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

        private static func tool(_ name: String, _ description: String) -> ToolDefinition {
            ToolDefinition(
                name: name,
                description: description,
                inputSchema: .object(properties: [:], required: [])
            )
        }
    }

#endif
