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
    /// deliberately when choosing a model:
    ///
    ///     swift test --traits MLX --filter MLXEmbedderEvalTests
    final class MLXEmbedderEvalTests: XCTestCase {
        /// The comparison that decides which encoder ships.
        ///
        /// Standings before this: lexical 67% hit / 0.61 MRR, Apple's
        /// `NLContextualEmbedding` 83% / 0.54, and fusing those two
        /// 92% / 0.72. A retrieval-trained encoder should beat the
        /// contextual model outright; the question worth answering is
        /// whether it beats the *fusion*, because that is what it would
        /// have to replace to justify a model download.
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
