#if os(iOS) || os(macOS) || os(watchOS) || os(tvOS) || os(visionOS)

import XCTest
@testable import Aria
@testable import AriaApple

/// Apple-platform tests for `AriaApple`. These run on macOS CI (and on iOS
/// simulators when explicitly invoked). They are gated by `#if` so the test
/// target compiles cleanly on Linux even though it produces no executable
/// tests there.
final class AriaAppleTests: XCTestCase {
    func testAriaAppleVersionMatchesCore() {
        XCTAssertEqual(
            Aria.version,
            AriaApple.version,
            "AriaApple.version must track Aria.version exactly"
        )
    }
}

#endif
