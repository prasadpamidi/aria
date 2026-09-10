import Aria
@testable import AriaTools
import XCTest

final class VegaLiteCompilerTests: XCTestCase {
    // MARK: - Grounding

    /// The model names fields; it never supplies values. If it names a
    /// field that is not there, the chart must fail loudly rather than
    /// render an empty axis — and the error carries the real field
    /// names so the failure is recoverable.
    func testUnknownFieldFailsWithTheAvailableNames() {
        XCTAssertThrowsError(
            try VegaLiteCompiler.compile(
                ChartIntent(kind: .line, dataRef: "r1", x: "day", y: "value"),
                rows: Self.rows
            )
        ) { error in
            XCTAssertEqual(
                error as? ChartCompilerError,
                // `x` is validated first, so "day" is the name reported.
                .unknownField(name: "day", available: ["date", "region", "value"])
            )
        }
    }

    func testEmptyDataFails() {
        XCTAssertThrowsError(
            try VegaLiteCompiler.compile(
                ChartIntent(kind: .bar, dataRef: "r1", x: "date", y: "value"),
                rows: []
            )
        ) { XCTAssertEqual($0 as? ChartCompilerError, .emptyData) }
    }

    /// Values in the spec must come from the rows the host supplied.
    func testDataIsInlinedFromTheHostRows() throws {
        let spec = try VegaLiteCompiler.compile(
            ChartIntent(kind: .line, dataRef: "r1", x: "date", y: "value"),
            rows: Self.rows
        )
        guard case let .object(top) = spec,
              case let .object(data) = top["data"],
              case let .array(values) = data["values"] else {
            return XCTFail("expected inlined data values")
        }
        XCTAssertEqual(values.count, 3)
    }

    // MARK: - Type inference

    /// The host has the values, so it infers types rather than asking
    /// the model to declare them.
    func testInfersQuantitativeTemporalAndNominal() throws {
        let spec = try VegaLiteCompiler.compile(
            ChartIntent(kind: .line, dataRef: "r1", x: "date", y: "value", series: "region"),
            rows: Self.rows
        )
        XCTAssertEqual(Self.type(of: "x", in: spec), "temporal")
        XCTAssertEqual(Self.type(of: "y", in: spec), "quantitative")
        XCTAssertEqual(Self.type(of: "color", in: spec), "nominal")
    }

    /// One non-numeric value makes the whole axis untrustworthy, so the
    /// field degrades to nominal rather than rendering a broken scale.
    func testOneBadValueDemotesQuantitativeToNominal() throws {
        var rows = Self.rows
        rows[1]["value"] = .string("n/a")
        let spec = try VegaLiteCompiler.compile(
            ChartIntent(kind: .bar, dataRef: "r1", x: "region", y: "value"),
            rows: rows
        )
        XCTAssertEqual(Self.type(of: "y", in: spec), "nominal")
    }

    /// A category that merely starts with a digit must not become a
    /// time axis — a false temporal is worse than a plain category.
    func testDigitLeadingCategoriesAreNotTemporal() throws {
        let rows: [[String: JSONValue]] = [
            ["label": .string("3 items"), "n": .integer(1)],
            ["label": .string("4 items"), "n": .integer(2)],
        ]
        let spec = try VegaLiteCompiler.compile(
            ChartIntent(kind: .bar, dataRef: "r1", x: "label", y: "n"),
            rows: rows
        )
        XCTAssertEqual(Self.type(of: "x", in: spec), "nominal")
    }

    // MARK: - Shape

    /// Pie has no axes — the same two fields mean angle and category.
    func testPieUsesThetaAndColorRatherThanAxes() throws {
        let spec = try VegaLiteCompiler.compile(
            ChartIntent(kind: .pie, dataRef: "r1", x: "region", y: "value"),
            rows: Self.rows
        )
        guard case let .object(top) = spec, case let .object(encoding) = top["encoding"] else {
            return XCTFail("no encoding")
        }
        XCTAssertNotNil(encoding["theta"])
        XCTAssertNil(encoding["x"])
    }

    /// An interactive chart the user cannot interrogate is a picture.
    func testTooltipsAreAlwaysEnabled() throws {
        let spec = try VegaLiteCompiler.compile(
            ChartIntent(kind: .scatter, dataRef: "r1", x: "date", y: "value"),
            rows: Self.rows
        )
        guard case let .object(top) = spec,
              case let .object(encoding) = top["encoding"],
              case let .array(tooltip) = encoding["tooltip"],
              case let .object(mark) = top["mark"] else {
            return XCTFail("no tooltip")
        }
        XCTAssertEqual(tooltip.count, 2)
        XCTAssertEqual(mark["tooltip"], .bool(true))
    }

    /// Every kind must compile — the enum exists so none of them can be
    /// a runtime surprise.
    func testEveryChartKindCompiles() throws {
        for kind in ChartKind.allCases {
            XCTAssertNoThrow(
                try VegaLiteCompiler.compile(
                    ChartIntent(kind: kind, dataRef: "r1", x: "region", y: "value"),
                    rows: Self.rows
                ),
                "\(kind) failed to compile"
            )
        }
    }

    // MARK: Private

    private static let rows: [[String: JSONValue]] = [
        ["date": .string("2026-01-01"), "value": .integer(3), "region": .string("west")],
        ["date": .string("2026-01-02"), "value": .integer(5), "region": .string("west")],
        ["date": .string("2026-01-03"), "value": .integer(4), "region": .string("east")],
    ]

    private static func type(of channel: String, in spec: JSONValue) -> String? {
        guard case let .object(top) = spec,
              case let .object(encoding) = top["encoding"],
              case let .object(field) = encoding[channel],
              case let .string(type) = field["type"] else {
            return nil
        }
        return type
    }
}
