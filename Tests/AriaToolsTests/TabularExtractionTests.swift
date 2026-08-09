import Aria
@testable import AriaTools
import XCTest

final class TabularExtractionTests: XCTestCase {
    /// A bare array is the simplest tool result shape.
    func testBareArray() {
        let value = JSONValue.array([Self.row(1), Self.row(2)])
        XCTAssertEqual(TabularExtraction.rows(from: value)?.count, 2)
        XCTAssertEqual(TabularExtraction.extractDetailed(from: value)?.path, [])
    }

    /// Envelope keys are checked in a fixed order, so a result with
    /// several arrays charts the same thing every time rather than
    /// depending on dictionary ordering.
    func testPrefersConventionalEnvelopeKeys() {
        let value = JSONValue.object([
            "warnings": .array([Self.row(9)]),
            "items": .array([Self.row(1), Self.row(2)]),
        ])
        let found = TabularExtraction.extractDetailed(from: value)
        XCTAssertEqual(found?.path, ["items"])
        XCTAssertEqual(found?.rows.count, 2)
    }

    func testFindsNestedRows() {
        let value = JSONValue.object([
            "data": .object(["records": .array([Self.row(1)])]),
        ])
        XCTAssertEqual(TabularExtraction.extractDetailed(from: value)?.path, ["data", "records"])
    }

    /// Tools that hand back JSON as a string are common enough to
    /// support — but only at the top level, since decoding strings
    /// buried inside a payload would be guessing.
    func testDecodesTopLevelJSONString() {
        let value = JSONValue.string(#"{"items":[{"x":1,"y":2}]}"#)
        XCTAssertEqual(TabularExtraction.rows(from: value)?.count, 1)
    }

    /// A mixed array is not a table. Charting only its object elements
    /// would silently drop data, which is worse than declining.
    func testMixedArrayIsNotATable() {
        let value = JSONValue.array([Self.row(1), .string("nope")])
        XCTAssertNil(TabularExtraction.rows(from: value))
    }

    func testEmptyArrayIsNotATable() {
        XCTAssertNil(TabularExtraction.rows(from: .array([])))
    }

    func testScalarsAndProseAreNotTables() {
        XCTAssertNil(TabularExtraction.rows(from: .integer(4)))
        XCTAssertNil(TabularExtraction.rows(from: .string("no data today")))
        XCTAssertNil(TabularExtraction.rows(from: .object(["note": .string("hi")])))
    }

    /// Ten thousand points is an unreadable chart and a slow one. The
    /// excess is dropped, and the caller is told so it can say so.
    func testTruncatesAndReportsOriginalCount() {
        let rows = (0 ..< 50).map { Self.row($0) }
        let found = TabularExtraction.extractDetailed(
            from: .array(rows),
            maximumRows: 10
        )
        XCTAssertEqual(found?.rows.count, 10)
        XCTAssertEqual(found?.truncatedFrom, 50)
    }

    func testNoTruncationReportsNil() {
        let found = TabularExtraction.extractDetailed(from: .array([Self.row(1)]))
        XCTAssertNil(found?.truncatedFrom)
    }

    /// End to end: a realistic MCP tool result should chart.
    func testRealisticToolResultCompilesToAChart() throws {
        let payload = JSONValue.object([
            "series": .array([
                .object(["date": .string("2026-01-01"), "weight_kg": .number(80.2)]),
                .object(["date": .string("2026-01-08"), "weight_kg": .number(79.6)]),
            ]),
        ])
        let rows = try XCTUnwrap(TabularExtraction.rows(from: payload))
        XCTAssertNoThrow(
            try VegaLiteCompiler.compile(
                ChartIntent(kind: .line, dataRef: "r1", x: "date", y: "weight_kg"),
                rows: rows
            )
        )
    }

    // MARK: Private

    private static func row(_ n: Int) -> JSONValue {
        .object(["x": .integer(Int64(n)), "y": .integer(Int64(n * 2))])
    }
}
