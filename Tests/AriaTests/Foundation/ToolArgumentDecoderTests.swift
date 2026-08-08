@testable import Aria
import XCTest

/// The payload a bridge receives is free-form text from a small model.
/// These cases are the dialects that text actually arrives in.
final class ToolArgumentDecoderTests: XCTestCase {
    // MARK: - The field failure

    /// `niora__get_fasting_status` declares `properties: {}`. Asked for
    /// "a JSON object matching the input schema" with nothing to
    /// encode, the model wrote prose, the bridge refused the call, and
    /// the assistant told the user it couldn't check their fasting
    /// status — a tool it had, that needed nothing, that would have
    /// answered.
    func testZeroArgumentToolSurvivesAnyPayload() {
        let schema = JSONSchema.object(properties: [:], required: [])
        for payload in ["none", "None", "no arguments", "N/A", "{'a': 1}", "{,}", "null", "[]"] {
            switch ToolArgumentDecoder.decode(payload, for: schema) {
            case let .success(decoded):
                XCTAssertEqual(decoded.arguments, [:], "payload: \(payload)")
            case let .failure(error):
                XCTFail("zero-argument tool refused \(payload): \(error)")
            }
        }
    }

    /// The same tolerance applies when every argument has a default —
    /// returning today's readiness beats refusing to answer.
    func testAllOptionalToolSurvivesAnUnreadablePayload() {
        let schema = JSONSchema.object(
            properties: ["date": .string()],
            required: []
        )
        guard case let .success(decoded) = ToolArgumentDecoder.decode("none", for: schema) else {
            return XCTFail("expected tolerance when nothing is required")
        }
        XCTAssertEqual(decoded.repair, .defaulted)
        XCTAssertEqual(decoded.arguments, [:])
    }

    // MARK: - Clean input stays clean

    func testWellFormedObjectIsUnrepaired() {
        let schema = JSONSchema.object(properties: ["city": .string()], required: ["city"])
        guard case let .success(decoded) = ToolArgumentDecoder.decode(
            #"{"city": "Tokyo"}"#,
            for: schema
        ) else {
            return XCTFail("expected success")
        }
        XCTAssertEqual(decoded.repair, .none)
        XCTAssertEqual(decoded.arguments["city"], .string("Tokyo"))
    }

    func testBlankPayloadIsAnEmptyObject() {
        guard case let .success(decoded) = ToolArgumentDecoder.decode(
            "   \n ",
            for: .object(properties: [:], required: [])
        ) else {
            return XCTFail("expected success")
        }
        XCTAssertEqual(decoded.repair, .blank)
    }

    // MARK: - Repairs

    func testFencedJSONIsUnfenced() {
        let schema = JSONSchema.object(properties: ["city": .string()], required: ["city"])
        guard case let .success(decoded) = ToolArgumentDecoder.decode(
            "```json\n{\"city\": \"Tokyo\"}\n```",
            for: schema
        ) else {
            return XCTFail("expected the fence to be stripped")
        }
        XCTAssertEqual(decoded.repair, .unfenced)
        XCTAssertEqual(decoded.arguments["city"], .string("Tokyo"))
    }

    /// A model that encodes its arguments twice sends a JSON string
    /// whose contents are the real object.
    func testDoubleEncodedPayloadIsUnwrapped() {
        let schema = JSONSchema.object(properties: ["city": .string()], required: ["city"])
        guard case let .success(decoded) = ToolArgumentDecoder.decode(
            #""{\"city\": \"Tokyo\"}""#,
            for: schema
        ) else {
            return XCTFail("expected the payload to be unwrapped")
        }
        XCTAssertEqual(decoded.repair, .unwrapped)
        XCTAssertEqual(decoded.arguments["city"], .string("Tokyo"))
    }

    func testObjectIsRecoveredFromSurroundingProse() {
        let schema = JSONSchema.object(properties: ["city": .string()], required: ["city"])
        guard case let .success(decoded) = ToolArgumentDecoder.decode(
            "Sure! Here are the arguments: {\"city\": \"Tokyo\"} — let me know.",
            for: schema
        ) else {
            return XCTFail("expected the object to be extracted")
        }
        XCTAssertEqual(decoded.repair, .extracted)
        XCTAssertEqual(decoded.arguments["city"], .string("Tokyo"))
    }

    /// A brace inside a quoted value must not end the scan early.
    func testExtractionRespectsBracesInsideStrings() {
        let schema = JSONSchema.object(properties: ["q": .string()], required: ["q"])
        guard case let .success(decoded) = ToolArgumentDecoder.decode(
            #"here: {"q": "a } brace"} done"#,
            for: schema
        ) else {
            return XCTFail("expected the full object")
        }
        XCTAssertEqual(decoded.arguments["q"], .string("a } brace"))
    }

    // MARK: - Failing when it matters

    /// Tolerance is scoped by the schema. A tool that needs a city and
    /// is given prose must say so — silently calling it with `{}` would
    /// trade a clear error for a confusing one from the server.
    func testUnreadablePayloadFailsWhenArgumentsAreRequired() {
        let schema = JSONSchema.object(properties: ["city": .string()], required: ["city"])
        guard case let .failure(error) = ToolArgumentDecoder.decode("none", for: schema) else {
            return XCTFail("expected failure when a required argument is missing")
        }
        guard case .unreadable = error else {
            return XCTFail("expected .unreadable, got \(error)")
        }
    }

    func testBareValueFailsWhenArgumentsAreRequired() {
        let schema = JSONSchema.object(properties: ["city": .string()], required: ["city"])
        guard case let .failure(error) = ToolArgumentDecoder.decode("\"Tokyo\"", for: schema) else {
            return XCTFail("expected failure for a bare scalar")
        }
        guard case .notAnObject = error else {
            return XCTFail("expected .notAnObject, got \(error)")
        }
    }

    /// The property that makes the next occurrence diagnosable: the
    /// message quotes what the model actually wrote, names what was
    /// missing, and shows the shape to send instead.
    func testFailureQuotesThePayloadAndNamesTheRequirement() {
        let schema = JSONSchema.object(properties: ["city": .string()], required: ["city"])
        guard case let .failure(error) = ToolArgumentDecoder.decode("no idea", for: schema) else {
            return XCTFail("expected failure")
        }
        XCTAssertTrue(error.description.contains("no idea"), error.description)
        XCTAssertTrue(error.description.contains("city"), error.description)
    }

    /// A model that pastes its reasoning into the arguments field
    /// shouldn't blow out the next prompt with the echo.
    func testQuotedPayloadIsBounded() {
        let schema = JSONSchema.object(properties: ["city": .string()], required: ["city"])
        guard case let .failure(error) = ToolArgumentDecoder.decode(
            String(repeating: "x", count: 5000),
            for: schema
        ) else {
            return XCTFail("expected failure")
        }
        XCTAssertLessThan(error.description.count, 400)
        XCTAssertTrue(error.description.contains("5000 chars"), error.description)
    }

    // MARK: - Guidance

    /// The line that prevents the failure rather than repairing it.
    func testGuidanceStatesTheEmptyObjectForZeroArgumentTools() {
        let guidance = ToolArgumentDecoder.payloadGuidance(
            for: .object(properties: [:], required: [])
        )
        XCTAssertTrue(guidance.contains("{}"), guidance)
    }

    func testGuidanceOffersDefaultsWhenEverythingIsOptional() {
        let guidance = ToolArgumentDecoder.payloadGuidance(
            for: .object(properties: ["date": .string()], required: [])
        )
        XCTAssertTrue(guidance.contains("{}"), guidance)
        XCTAssertTrue(guidance.contains("optional"), guidance)
    }

    func testGuidanceNamesARequiredFieldWhenThereIsOne() {
        let guidance = ToolArgumentDecoder.payloadGuidance(
            for: .object(properties: ["city": .string()], required: ["city"])
        )
        XCTAssertTrue(guidance.contains("city"), guidance)
    }

    // MARK: - Type fidelity

    /// `NSNumber` bridges Bool, Int and Double alike; `true` must not
    /// decode as `1`.
    func testBooleansAndNumbersKeepTheirTypes() {
        let schema = JSONSchema.object(properties: [:], required: [])
        guard case let .success(decoded) = ToolArgumentDecoder.decode(
            #"{"flag": true, "count": 3, "ratio": 1.5}"#,
            for: schema
        ) else {
            return XCTFail("expected success")
        }
        XCTAssertEqual(decoded.arguments["flag"], .bool(true))
        XCTAssertEqual(decoded.arguments["count"], .integer(3))
        XCTAssertEqual(decoded.arguments["ratio"], .number(1.5))
    }

    func testNestedStructuresSurvive() {
        let schema = JSONSchema.object(properties: [:], required: [])
        guard case let .success(decoded) = ToolArgumentDecoder.decode(
            #"{"items": [{"id": 1}], "meta": null}"#,
            for: schema
        ) else {
            return XCTFail("expected success")
        }
        XCTAssertEqual(decoded.arguments["items"], .array([.object(["id": .integer(1)])]))
        XCTAssertEqual(decoded.arguments["meta"], .null)
    }
}
