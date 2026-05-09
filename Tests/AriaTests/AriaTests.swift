import XCTest
@testable import Aria
@testable import AriaTesting

/// Smoke tests for the core target. These run on Linux and Apple platforms
/// alike — they must not depend on any Apple framework.
final class AriaTests: XCTestCase {
    func testAriaVersionIsNotEmpty() {
        XCTAssertFalse(Aria.version.isEmpty, "Aria.version should be set")
    }

    func testAriaTestingVersionMatchesCore() {
        XCTAssertEqual(
            Aria.version,
            AriaTesting.version,
            "AriaTesting.version must track Aria.version exactly"
        )
    }
}
