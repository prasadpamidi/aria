@testable import Aria
import XCTest

/// The failure these exist for: a 0.8B model called a weather tool with
/// `{"days": "1", "latitude": "56.35"}` and the server refused it —
/// *"Invalid days: must be a finite number, received string"*. Right
/// tool, right intent, right values, defeated by quotation marks.
final class ToolArgumentCoercionTests: XCTestCase {
    // MARK: - The regression

    func testQuotedNumbersAreCoercedToTheirDeclaredTypes() {
        let coerced = ToolArgumentCoercion.coerce(
            .object([
                "days": .string("1"),
                "latitude": .string("56.35"),
                "city_name": .string("Dublin"),
                "include_alerts": .string("true"),
            ]),
            to: Self.weatherSchema
        )
        XCTAssertEqual(coerced, .object([
            "days": .integer(1),
            "latitude": .number(56.35),
            "city_name": .string("Dublin"),
            "include_alerts": .bool(true),
        ]))
    }

    // MARK: - Restraint

    /// A value that is not losslessly convertible is left alone. The
    /// server's own error beats a number this invented.
    func testUnconvertibleValuesAreLeftForTheServerToReject() {
        let coerced = ToolArgumentCoercion.coerce(
            .object(["days": .string("next week")]),
            to: Self.weatherSchema
        )
        XCTAssertEqual(coerced, .object(["days": .string("next week")]))
    }

    /// Truncating 1.7 to 1 would change what the model asked for.
    func testFractionalValuesAreNotTruncatedIntoIntegers() {
        let coerced = ToolArgumentCoercion.coerce(
            .object(["days": .number(1.7)]),
            to: Self.weatherSchema
        )
        XCTAssertEqual(coerced, .object(["days": .number(1.7)]))
    }

    /// "yes" is a guess about intent, not a reading of the value.
    func testOnlyJSONBooleanSpellingsAreAccepted() {
        for text in ["yes", "1", "on", "Y"] {
            let coerced = ToolArgumentCoercion.coerce(
                .object(["include_alerts": .string(text)]),
                to: Self.weatherSchema
            )
            XCTAssertEqual(
                coerced,
                .object(["include_alerts": .string(text)]),
                "\"\(text)\" should not have been read as a boolean"
            )
        }
    }

    /// A field the schema does not describe has no contract to enforce.
    func testUndeclaredFieldsPassThroughUntouched() {
        let coerced = ToolArgumentCoercion.coerce(
            .object(["mystery": .string("42")]),
            to: Self.weatherSchema
        )
        XCTAssertEqual(coerced, .object(["mystery": .string("42")]))
    }

    func testCorrectlyTypedArgumentsAreUnchanged() {
        let already = JSONValue.object([
            "days": .integer(3),
            "latitude": .number(37.7),
            "city_name": .string("Dublin"),
        ])
        XCTAssertEqual(ToolArgumentCoercion.coerce(already, to: Self.weatherSchema), already)
    }

    // MARK: - Shape

    func testNestedObjectsAndArraysAreCoercedRecursively() {
        let schema = JSONSchema.object(
            properties: [
                "points": .array(items: .object(
                    properties: ["value": .number(description: nil)],
                    required: []
                ))
            ],
            required: []
        )
        let coerced = ToolArgumentCoercion.coerce(
            .object(["points": .array([.object(["value": .string("2.5")])])]),
            to: schema
        )
        XCTAssertEqual(
            coerced,
            .object(["points": .array([.object(["value": .number(2.5)])])])
        )
    }

    /// The mirror case: a bare number where a string is declared.
    func testNumbersAreStringifiedWhenTheSchemaWantsText() {
        let coerced = ToolArgumentCoercion.coerce(
            .object(["city_name": .integer(94568)]),
            to: Self.weatherSchema
        )
        XCTAssertEqual(coerced, .object(["city_name": .string("94568")]))
    }

    // MARK: Private

    private static let weatherSchema = JSONSchema.object(
        properties: [
            "city_name": .string(description: nil, enumValues: nil),
            "days": .integer(description: nil),
            "latitude": .number(description: nil),
            "include_alerts": .boolean(description: nil),
        ],
        required: ["city_name"]
    )
}
