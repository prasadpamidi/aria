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
        /// Evals that need model assets are opt-in.
        ///
        /// `NLContextualEmbedding` downloads its model on first use —
        /// under 100MB, OS-managed, and unbounded. A unit suite must
        /// not do that: on a fresh CI runner the request either adds
        /// minutes to every build or never returns at all, and a test
        /// that hangs is worse than one that fails, because nothing
        /// says which test is stuck.
        ///
        /// It hung the macOS job exactly once, on the first run where
        /// this file's contextual test actually executed — the two runs
        /// before it were cancelled by pushes and never got there.
        ///
        ///     ARIA_RUN_EVALS=1 swift test --filter ToolSelectionEvalTests
        static var assetEvalsEnabled: Bool {
            ProcessInfo.processInfo.environment["ARIA_RUN_EVALS"] == "1"
        }

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
            let eval = ToolSelectionEval(corpus: ToolSelectionFixtures.corpus, cases: ToolSelectionFixtures.cases)

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

        /// Apple's contextual (BERT) embedding against everything else.
        ///
        /// `NLEmbedding` averages static word vectors; this reads the
        /// whole string. The question is whether that closes the four
        /// paraphrase cases every ranker currently misses — "what did I
        /// eat today?", "what did I lift last week?" — without giving
        /// up the precision lexical has on identifier matches.
        ///
        /// Assets download on demand, so this skips rather than fails
        /// when they are unavailable: a network-dependent assertion in
        /// a unit suite is a flake, not a signal.
        func testContextualEmbeddingRanker() async throws {
            try XCTSkipUnless(
                Self.assetEvalsEnabled,
                "Needs an asset download; set ARIA_RUN_EVALS=1"
            )
            guard #available(iOS 17.0, macOS 14.0, *),
                  let embedder = NLContextualEmbedder() else {
                throw XCTSkip("NLContextualEmbedding unavailable")
            }
            do {
                try await embedder.prepare()
            } catch {
                throw XCTSkip("NLContextualEmbedding assets unavailable: \(error)")
            }

            let eval = ToolSelectionEval(corpus: ToolSelectionFixtures.corpus, cases: ToolSelectionFixtures.cases)
            let contextual = await eval.run(
                EmbeddingToolSelector(embedder: embedder, fallback: nil),
                label: "nl-contextual"
            )
            let fused = await eval.run(
                FusedToolSelector(selectors: [
                    LexicalToolSelector(),
                    EmbeddingToolSelector(embedder: embedder, fallback: nil),
                ]),
                label: "fused(lexical + nl-contextual)"
            )

            print("\n" + contextual.summary())
            print("\n" + fused.summary() + "\n")

            XCTAssertGreaterThan(
                contextual.hitRate,
                0,
                "A loaded contextual model must rank something"
            )
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
            let junkTermCases = ToolSelectionFixtures.cases.filter { !$0.misleading.isEmpty }
            let eval = ToolSelectionEval(corpus: ToolSelectionFixtures.corpus, cases: junkTermCases)

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
                from: ToolSelectionFixtures.corpus,
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
                from: ToolSelectionFixtures.corpus,
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
                from: ToolSelectionFixtures.corpus,
                query: "zzzz qqqq",
                limit: 5
            )
            XCTAssertTrue(selected.isEmpty)
        }

    }

#endif
