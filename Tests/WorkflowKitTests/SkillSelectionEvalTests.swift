import Aria
import WorkflowKit
import WorkflowKitTesting
import XCTest

// MARK: - SkillSelectionEvalTests

/// What does ranking the skill catalogue actually buy?
///
/// The tool-selection argument, on the surface that had no selection at
/// all until recently. Worth its own measurement because the cost shape
/// differs: an unranked *tool* costs its schema in the prompt, while an
/// unranked *skill* costs the chance the model loads it — a whole
/// round-trip and a body-sized tool result.
@MainActor
final class SkillSelectionEvalTests: XCTestCase {
    func testRankingTheCatalogueRemovesDistractorsWithoutLosingRecall() async throws {
        let (provider, directory) = try SkillFixtures.makeProvider()
        defer { SkillFixtures.tearDown(directory) }

        let eval = SkillSelectionEval(cases: SkillFixtures.cases(), provider: provider)

        let unranked = eval.runUnranked()
        let lexical = await eval.runRanked(
            selector: LexicalToolSelector(),
            label: "ranked · lexical"
        )

        print("\n" + unranked.summary())
        print(lexical.summary() + "\n")

        // The constraint any reduction has to respect: ranking that
        // hides the skill the turn needs is worse than no ranking.
        XCTAssertEqual(
            lexical.recall,
            unranked.recall,
            "ranking dropped a skill the turn needed"
        )
        XCTAssertLessThan(
            lexical.averageDistractors,
            unranked.averageDistractors,
            "ranking offered no fewer irrelevant skills than sending everything"
        )
    }

    /// The catalogue grows with what the user installs, and the
    /// unranked block grows with it. The ranked one should not.
    func testTheRankedBlockDoesNotGrowWithTheCatalogue() async throws {
        let (provider, directory) = try SkillFixtures.makeProvider()
        defer { SkillFixtures.tearDown(directory) }

        let eval = SkillSelectionEval(cases: SkillFixtures.cases(), provider: provider)
        let ranked = await eval.runRanked(selector: LexicalToolSelector(), limit: 3)
        XCTAssertLessThanOrEqual(ranked.averageDistractors, 2)
    }
}
