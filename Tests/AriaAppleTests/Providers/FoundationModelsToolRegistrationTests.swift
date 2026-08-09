#if canImport(FoundationModels)
    import Aria
    @testable import AriaApple
    import FoundationModels
    import XCTest

    // MARK: - FoundationModelsToolRegistrationTests

    /// One malformed tool must not take the turn down.
    ///
    /// `LanguageModelSession(tools:)` fails as a whole when any tool is
    /// unregistrable, and the failure surfaces as an opaque
    /// `tokengeneration Code=10` during prefill — no tokens, no tool
    /// calls, nothing naming the offender. It cost several rounds of
    /// diagnosis from field traces before the shape was recognisable.
    ///
    /// Runtime-named tools make it reachable. Workflow tools derive
    /// their identifier by snake-casing a user-entered title, so
    /// "Morning Brief" and "morning brief!" collide, and a title with
    /// an accent yields a non-ASCII name.
    @available(iOS 26.0, macOS 26.0, *)
    final class FoundationModelsToolRegistrationTests: XCTestCase {
        /// Same guard the sibling FoundationModels suites use.
        ///
        /// XCTest's Objective-C-driven discovery instantiates every
        /// class regardless of `@available`, so a suite whose fixtures
        /// touch FoundationModels metadata runs on hosts where the
        /// framework cannot back them — and aborts the whole process
        /// with signal 6 rather than failing one test. That took CI
        /// down while every other FM suite skipped cleanly.
        override func setUpWithError() throws {
            guard #available(iOS 26.0, macOS 26.0, *) else {
                throw XCTSkip("Requires iOS 26 / macOS 26 runtime")
            }
            try XCTSkipUnless(
                SystemLanguageModel.default.isAvailable,
                "Requires an available on-device model to build @Generable tools"
            )
        }

        func testDuplicateNamesAreRejectedKeepingTheFirst() {
            let (accepted, rejected) = FoundationModelsProvider.registrable([
                StubTool(name: "run_morning_brief"),
                StubTool(name: "run_morning_brief"),
            ])
            XCTAssertEqual(accepted.count, 1)
            XCTAssertEqual(rejected.count, 1)
            XCTAssertTrue(rejected[0].contains("duplicate"), rejected[0])
        }

        func testNonASCIINamesAreRejected() {
            let (accepted, rejected) = FoundationModelsProvider.registrable([
                StubTool(name: "run_café_brief"),
            ])
            XCTAssertTrue(accepted.isEmpty)
            XCTAssertTrue(rejected[0].contains("outside"), rejected[0])
        }

        func testOverlongNamesAreRejected() {
            let (accepted, rejected) = FoundationModelsProvider.registrable([
                StubTool(name: String(repeating: "a", count: 200)),
            ])
            XCTAssertTrue(accepted.isEmpty)
            XCTAssertTrue(rejected[0].contains("characters"), rejected[0])
        }

        func testEmptyNameIsRejected() {
            let (accepted, _) = FoundationModelsProvider.registrable([StubTool(name: "")])
            XCTAssertTrue(accepted.isEmpty)
        }

        /// The point of the exercise: the good tools still ship.
        func testValidToolsSurviveAlongsideABadOne() {
            let (accepted, rejected) = FoundationModelsProvider.registrable([
                StubTool(name: "current_time"),
                StubTool(name: "run_café_brief"),
                StubTool(name: "niora__get_fasting_status"),
            ])
            XCTAssertEqual(accepted.map(\.name), ["current_time", "niora__get_fasting_status"])
            XCTAssertEqual(rejected.count, 1)
        }

        /// Rejection reasons name the tool, since the whole failure
        /// mode was that nothing did.
        func testRejectionReasonNamesTheTool() {
            let (_, rejected) = FoundationModelsProvider.registrable([
                StubTool(name: "run_café_brief"),
            ])
            XCTAssertTrue(rejected[0].contains("run_caf"), rejected[0])
        }
    }

    // MARK: - StubTool

    @available(iOS 26.0, macOS 26.0, *)
    private struct StubTool: FoundationModels.Tool {
        @Generable
        struct Arguments: Codable {
            var value: String
        }

        typealias Output = String

        let name: String
        var description: String { "A stub tool." }

        func call(arguments _: Arguments) async throws -> String { "" }
    }
#endif
