@testable import Aria
import XCTest

/// A bare error reads to a small model as "try another route".
///
/// The field turn: asked how much water the user drank, the agent
/// called the right tool, got `Authentication required`, then called an
/// unrelated skill, a URL codec, and a calculator with the literal
/// expression `2000` — and answered "You drank 2000ml of water today."
/// Every step was a plausible local decision. What no bare error says
/// is that failing to answer is acceptable and inventing an answer is
/// not.
final class ToolFailureTests: XCTestCase {
    func testFailureCarriesGuidance() {
        let rendered = ToolFailure.render(
            ToolExecutionResult(
                output: .object(["error": .string("Authentication required")]),
                isError: true,
                duration: .milliseconds(1)
            )
        )
        XCTAssertTrue(rendered.contains("Authentication required"), "The error itself must survive")
        XCTAssertTrue(rendered.contains(ToolFailure.guidance))
    }

    /// Success must stay clean — guidance on every result would spend
    /// budget on turns where nothing went wrong and train the model to
    /// ignore it.
    func testSuccessIsUnchanged() {
        let rendered = ToolFailure.render(
            ToolExecutionResult(
                output: .object(["ml": .integer(2000)]),
                isError: false,
                duration: .milliseconds(1)
            )
        )
        XCTAssertFalse(rendered.contains(ToolFailure.guidance))
        XCTAssertTrue(rendered.contains("2000"))
    }

    /// Phrased as an action to take, not a behaviour to avoid: a model
    /// does not believe it is fabricating, so "don't fabricate" names
    /// nothing it can act on.
    @MainActor
    func testGuidanceNamesTheActionToTake() {
        XCTAssertTrue(ToolFailure.guidance.contains("Tell the user"))
        XCTAssertTrue(ToolFailure.guidance.lowercased().contains("failed"))
    }

    /// An unrenderable payload still reports as a failure rather than
    /// silently becoming an empty success.
    func testUnrenderableErrorStillCarriesGuidance() {
        let rendered = ToolFailure.render(
            ToolExecutionResult(output: .null, isError: true, duration: .milliseconds(1))
        )
        XCTAssertTrue(rendered.contains(ToolFailure.guidance))
    }
}
