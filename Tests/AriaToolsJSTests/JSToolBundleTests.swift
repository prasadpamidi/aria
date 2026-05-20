import Aria
import AriaToolsJS
import Foundation
import XCTest

// MARK: - JSToolBundleTests

final class JSToolBundleTests: XCTestCase {
    func testRoundTripsValidBundle() throws {
        let original = JSToolBundle(
            id: "com.example.weather",
            name: "weather",
            displayName: "Weather",
            description: "Look up the weather.",
            version: "1.0.0",
            author: "Jane",
            capabilities: [.http, .json],
            inputSchema: .object(
                properties: ["city": .string()],
                required: ["city"]
            ),
            main: "async function call(input) { return { city: input.city }; }"
        )
        let data = try original.encoded()
        let decoded = try JSToolBundle.load(from: data)
        XCTAssertEqual(decoded, original)
    }

    func testRejectsMissingId() throws {
        let bad = #"""
        {
          "manifestVersion": 1,
          "id": "",
          "name": "x",
          "description": "d",
          "version": "1",
          "capabilities": [],
          "inputSchema": {"type": "object", "properties": {}},
          "main": "async function call(){}"
        }
        """#
        XCTAssertThrowsError(try JSToolBundle.load(from: Data(bad.utf8))) { error in
            XCTAssertEqual(error as? JSToolBundleError, .missingField("id"))
        }
    }

    func testRejectsMissingMain() throws {
        let bad = #"""
        {
          "manifestVersion": 1,
          "id": "com.example.x",
          "name": "x",
          "description": "d",
          "version": "1",
          "capabilities": [],
          "inputSchema": {"type": "object", "properties": {}},
          "main": ""
        }
        """#
        XCTAssertThrowsError(try JSToolBundle.load(from: Data(bad.utf8))) { error in
            XCTAssertEqual(error as? JSToolBundleError, .missingField("main"))
        }
    }

    func testRejectsFutureManifestVersion() throws {
        let future = #"""
        {
          "manifestVersion": 99,
          "id": "com.example.x",
          "name": "x",
          "description": "d",
          "version": "1",
          "capabilities": [],
          "inputSchema": {"type": "object", "properties": {}},
          "main": "async function call(){}"
        }
        """#
        XCTAssertThrowsError(try JSToolBundle.load(from: Data(future.utf8))) { error in
            XCTAssertEqual(error as? JSToolBundleError, .unsupportedManifestVersion(99))
        }
    }

    func testDisplayNameFallsBackToName() throws {
        let bundle = JSToolBundle(
            id: "com.example.x",
            name: "raw_name",
            displayName: nil,
            description: "d",
            version: "1",
            capabilities: [],
            inputSchema: .object(properties: [:]),
            main: "async function call(){}"
        )
        XCTAssertEqual(bundle.resolvedDisplayName, "raw_name")
    }

    func testCapabilitySetMembership() throws {
        let bundle = JSToolBundle(
            id: "com.example.x",
            name: "x",
            description: "d",
            version: "1",
            capabilities: [.http, .clipboard],
            inputSchema: .object(properties: [:]),
            main: "async function call(){}"
        )
        XCTAssertTrue(bundle.capabilitySet.contains(.http))
        XCTAssertFalse(bundle.capabilitySet.contains(.notify))
    }
}

// MARK: - JSToolCapabilityTests

final class JSToolCapabilityTests: XCTestCase {
    func testUserVisibleSideEffectsOnlySurfacesEmittingCapabilities() {
        // http and json are passive; share/notify/clipboard touch
        // user-perceptible surfaces and should be highlighted in
        // install UI.
        let set: Set<JSToolCapability> = [.http, .json, .share, .notify]
        XCTAssertEqual(set.userVisibleSideEffects, [.share, .notify])
    }

    func testAllCasesHaveDisplayName() {
        for cap in JSToolCapability.allCases {
            XCTAssertFalse(cap.displayName.isEmpty)
            XCTAssertFalse(cap.userDescription.isEmpty)
        }
    }
}
