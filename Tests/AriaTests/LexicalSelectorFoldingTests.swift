@testable import Aria
import AriaTesting
import XCTest

// MARK: - LexicalSelectorFoldingTests

/// Regression cover for stopwords eating a folded domain term.
final class LexicalSelectorFoldingTests: XCTestCase {
    /// "fasting" folds to "fast", and "fast" is a stopword. Subtracting
    /// stopwords *after* folding therefore erased the subject of the
    /// query, and the assembler — reading an empty ranking as "nothing
    /// is relevant" — offered the model no tools at all.
    func testFoldedDomainTermSurvivesTheStopwordList() async {
        let fasting = TaskFixtures.cases().first { $0.query.contains("fasting") }!
        let ranked = await LexicalToolSelector().select(
            from: fasting.tools.map(\.definition),
            query: fasting.query,
            limit: 6
        )
        XCTAssertEqual(ranked.first?.name, fasting.expectedTool)
    }

    /// The list still does the job it was added for: a bare generic
    /// adjective must not decide the match.
    func testBareAdjectiveIsStillStopped() async {
        let terms = Set(LexicalToolSelector.tokenize(
            "give me a fast quick current recipe",
            removing: LexicalToolSelector.defaultStopWords
        ))
        XCTAssertFalse(terms.contains("fast"))
        XCTAssertFalse(terms.contains("quick"))
        XCTAssertFalse(terms.contains("current"))
        // The subject survives — the list removes framing, not meaning.
        XCTAssertTrue(terms.contains("recipe"), "surviving: \(terms)")
    }
}
