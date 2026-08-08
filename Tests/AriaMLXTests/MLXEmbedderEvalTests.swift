#if ARIA_MLX
    import Aria
    import AriaMLX
    import AriaTesting
    import XCTest

    // MARK: - MLXEmbedderEvalTests

    /// Measures an MLX sentence encoder on the same corpus as every
    /// other ranker.
    ///
    /// Downloads weights on first run, so it skips rather than fails
    /// when the network or the Hub is unavailable — a network-dependent
    /// assertion in a unit suite is a flake, not a signal. Run it
    /// deliberately when choosing a model. The SwiftPM CLI cannot run
    /// it — mlx-swift's Metal kernels only build under Xcode's build
    /// system, and `swift build` emits no metallib at all, so every
    /// call fails inside MLX before reaching a test. Use xcodebuild,
    /// and note that `MLX` is not a default trait:
    ///
    ///     xcodebuild test -scheme Aria-Package \
    ///       -destination 'platform=macOS,arch=arm64' \
    ///       -only-testing:AriaMLXTests/MLXEmbedderEvalTests \
    ///       -skipPackagePluginValidation -skipMacroValidation
    final class MLXEmbedderEvalTests: XCTestCase {
        /// The comparison that decides which encoder ships.
        ///
        /// Measured on the field corpus (macOS, Xcode test run — the
        /// SwiftPM CLI cannot build mlx-swift's Metal kernels):
        ///
        ///     ranker                         hit  top-1   MRR  misled
        ///     lexical                        67%    58%  0.61      0%
        ///     NLEmbedding                    58%    25%  0.39      8%
        ///     NLContextualEmbedding          83%    25%  0.54      0%
        ///     fused(lexical + contextual)    92%    58%  0.72      0%
        ///     mlx/bge-small                 100%    58%  0.76      8%
        ///     fused(lexical + bge-small)    100%    67%  0.79      0%
        ///
        /// A 33M-parameter retrieval encoder answers every case,
        /// including "what did I lift last week?", which nothing else
        /// tried could reach — lift/workout is a domain synonym only a
        /// trained retriever carries.
        ///
        /// It is still misled alone, and by the same query that started
        /// all of this: "give me a quick recipe idea" ranks
        /// `run_quick_add_to_groceries_remix` first. Semantic
        /// similarity falls for the junk adjective too — it is simply a
        /// different mechanism for the same mistake. Fusing with
        /// lexical, whose stopword list rejects "quick", removes it.
        ///
        /// So the two rankers are complements rather than rivals, which
        /// is the one conclusion that has survived every measurement
        /// here.
        func testBGESmallOnTheFieldCorpus() async throws {
            let embedder = MLXEmbedder(model: .bgeSmall)
            do {
                try await embedder.prepare()
            } catch {
                throw XCTSkip("Could not load bge-small: \(error)")
            }

            let eval = ToolSelectionFixtures.eval
            let embedding = await eval.run(
                EmbeddingToolSelector(embedder: embedder, fallback: nil),
                label: "mlx/bge-small"
            )
            let fused = await eval.run(
                FusedToolSelector(selectors: [
                    LexicalToolSelector(),
                    EmbeddingToolSelector(embedder: embedder, fallback: nil),
                ]),
                label: "fused(lexical + mlx/bge-small)"
            )

            print("\n" + embedding.summary())
            print("\n" + fused.summary() + "\n")

            XCTAssertGreaterThan(embedding.hitRate, 0, "A loaded encoder must rank something")
        }

        /// Vectors must be usable as vectors: fixed width, L2-normalised,
        /// and actually distinguishing related text from unrelated.
        ///
        /// Worth asserting separately because a mis-wired attention mask
        /// produces plausible-looking output that ranks badly — every
        /// short string drifts toward whatever the pad token embeds to,
        /// and nothing about the shape of the result reveals it.
        func testEmbeddingsAreNormalisedAndDiscriminating() async throws {
            let embedder = MLXEmbedder(model: .bgeSmall)
            do {
                try await embedder.prepare()
            } catch {
                throw XCTSkip("Could not load bge-small: \(error)")
            }

            let vectors = try await embedder.embed([
                "The user's weight trend over time.",
                "Record a weight measurement for the user in kilograms.",
                "Get the current weather for a city.",
            ])

            XCTAssertEqual(vectors.count, 3)
            let width = try XCTUnwrap(vectors.first?.count)
            XCTAssertTrue(vectors.allSatisfy { $0.count == width }, "Ragged batch must pad")

            for vector in vectors {
                let norm = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
                XCTAssertEqual(norm, 1.0, accuracy: 0.01, "Vectors must be L2-normalised")
            }

            let related = Self.cosine(vectors[0], vectors[1])
            let unrelated = Self.cosine(vectors[0], vectors[2])
            XCTAssertGreaterThan(
                related,
                unrelated,
                "Two weight tools must sit closer together than a weight tool and a weather tool"
            )
        }

        private static func cosine(_ lhs: [Float], _ rhs: [Float]) -> Float {
            zip(lhs, rhs).reduce(0) { $0 + $1.0 * $1.1 }
        }
    }
#endif
