import Aria
import Foundation

// MARK: - ChartKind

/// The visualisations a model may ask for.
///
/// An enum rather than a string, so an invalid chart type is
/// unrepresentable rather than a runtime failure. This is the whole
/// reason the model is not asked to author a Vega-Lite spec: given free
/// text it will eventually emit `"linechart"`, `"line_chart"`, or a
/// spec with a subtly wrong encoding block, and each of those is a
/// broken chart in front of a user.
public enum ChartKind: String, Codable, Sendable, CaseIterable {
    case line
    case bar
    case area
    case scatter
    case pie

    // MARK: Internal

    /// Vega-Lite mark name.
    var mark: String {
        switch self {
        case .line: "line"
        case .bar: "bar"
        case .area: "area"
        case .scatter: "point"
        case .pie: "arc"
        }
    }
}

// MARK: - ChartIntent

/// What the model emits when it decides something should be a chart.
///
/// Deliberately tiny — roughly thirty tokens of output against the
/// several hundred a Vega-Lite spec would cost, which matters against a
/// 4,096-token window that also has to hold the data being charted.
///
/// Note what is *absent*: the data. The model names a tool result it
/// has already seen and the fields within it; the host supplies the
/// rows. A model that retypes numbers eventually invents them, and an
/// invented number wearing the authority of a chart is worse than an
/// invented sentence. Keeping values out of the model's output makes
/// charts structurally grounded rather than grounded by inspection.
public struct ChartIntent: Codable, Hashable, Sendable {
    // MARK: Lifecycle

    public init(
        kind: ChartKind,
        dataRef: String,
        x: String,
        y: String,
        series: String? = nil,
        title: String? = nil
    ) {
        self.kind = kind
        self.dataRef = dataRef
        self.x = x
        self.y = y
        self.series = series
        self.title = title
    }

    // MARK: Public

    public let kind: ChartKind
    /// Identifier of a tool result the host is holding.
    public let dataRef: String
    /// Field name for the horizontal axis (or category, for pie).
    public let x: String
    /// Field name for the vertical axis (or magnitude, for pie).
    public let y: String
    /// Optional field to split the data into multiple series.
    public let series: String?
    public let title: String?
}

// MARK: - ChartCompilerError

public enum ChartCompilerError: Error, Equatable, Sendable {
    /// The referenced tool result is not held by the host.
    case unresolvedDataRef(String)
    /// The rows contained no usable records.
    case emptyData
    /// A named field is absent from the data.
    ///
    /// Carries what *was* available, because the model naming a field
    /// that does not exist is the most likely failure here and the
    /// recovery is to tell it the real names.
    case unknownField(name: String, available: [String])
}

// MARK: - ChartDataType

/// Vega-Lite field type, inferred from the data rather than declared by
/// the model — the host has the values, so it can tell.
enum ChartDataType: String {
    case quantitative
    case temporal
    case nominal
}

// MARK: - VegaLiteCompiler

/// Turns a `ChartIntent` plus real rows into a Vega-Lite spec.
///
/// Improving charts — nicer axes, formatting, colour, legends — happens
/// here, and needs no prompt change and no model change. That
/// separation is the payoff for keeping the model's output small.
public enum VegaLiteCompiler {
    // MARK: Public

    /// Vega-Lite schema this compiler emits against.
    public static let schema = "https://vega.github.io/schema/vega-lite/v5.json"

    /// - Parameters:
    ///   - intent: What the model asked for.
    ///   - rows: The tool result's records, supplied by the host.
    /// - Returns: A Vega-Lite spec as `JSONValue`, ready to serialise.
    public static func compile(
        _ intent: ChartIntent,
        rows: [[String: JSONValue]]
    ) throws -> JSONValue {
        guard !rows.isEmpty else {
            throw ChartCompilerError.emptyData
        }
        let available = Self.fieldNames(in: rows)
        for field in [intent.x, intent.y] + (intent.series.map { [$0] } ?? []) {
            guard available.contains(field) else {
                throw ChartCompilerError.unknownField(name: field, available: available.sorted())
            }
        }

        var encoding: [String: JSONValue] = [
            "x": Self.field(intent.x, type: Self.inferType(of: intent.x, in: rows)),
            "y": Self.field(intent.y, type: Self.inferType(of: intent.y, in: rows)),
        ]
        if let series = intent.series {
            encoding["color"] = Self.field(series, type: .nominal)
        }

        // Pie has no axes: the fields mean angle and category instead.
        if intent.kind == .pie {
            encoding = [
                "theta": Self.field(intent.y, type: .quantitative),
                "color": Self.field(intent.x, type: .nominal),
            ]
        }

        // Tooltips are on by default. An interactive chart the user
        // cannot interrogate is a picture, and `tooltip: true` is the
        // whole cost of not shipping one.
        encoding["tooltip"] = .array(
            ([intent.x, intent.y] + (intent.series.map { [$0] } ?? [])).map { name in
                .object([
                    "field": .string(name),
                    "type": .string(Self.inferType(of: name, in: rows).rawValue),
                ])
            }
        )

        var spec: [String: JSONValue] = [
            "$schema": .string(Self.schema),
            "data": .object(["values": .array(rows.map { .object($0) })]),
            "mark": .object([
                "type": .string(intent.kind.mark),
                "tooltip": .bool(true),
                "point": .bool(intent.kind == .line),
            ]),
            "encoding": .object(encoding),
            "width": .string("container"),
            "autosize": .object(["type": .string("fit"), "contains": .string("padding")]),
        ]
        if let title = intent.title, !title.isEmpty {
            spec["title"] = .string(title)
        }
        return .object(spec)
    }

    // MARK: Private

    private static func field(_ name: String, type: ChartDataType) -> JSONValue {
        .object(["field": .string(name), "type": .string(type.rawValue)])
    }

    private static func fieldNames(in rows: [[String: JSONValue]]) -> Set<String> {
        rows.reduce(into: Set<String>()) { names, row in
            names.formUnion(row.keys)
        }
    }

    /// Infer a field's type from its values.
    ///
    /// Order matters: numbers first, then anything date-shaped, then
    /// nominal. A field is only quantitative if *every* present value
    /// is numeric — one stray `"n/a"` makes the axis meaningless, and
    /// nominal at least renders something honest.
    private static func inferType(
        of field: String,
        in rows: [[String: JSONValue]]
    ) -> ChartDataType {
        let values = rows.compactMap { $0[field] }.filter { value in
            if case .null = value {
                return false
            }
            return true
        }
        guard !values.isEmpty else {
            return .nominal
        }
        let allNumeric = values.allSatisfy { value in
            switch value {
            case .integer, .number: true
            default: false
            }
        }
        if allNumeric {
            return .quantitative
        }
        let allDateLike = values.allSatisfy { value in
            guard case let .string(text) = value else {
                return false
            }
            return Self.looksLikeDate(text)
        }
        return allDateLike ? .temporal : .nominal
    }

    /// ISO-8601-ish detection, deliberately narrow. A false positive
    /// here turns a category axis into a broken time axis, which is a
    /// worse outcome than a date rendered as a category.
    private static func looksLikeDate(_ text: String) -> Bool {
        guard text.count >= 8, let first = text.first, first.isNumber else {
            return false
        }
        let separators = text.filter { $0 == "-" || $0 == "/" }.count
        guard separators >= 2 else {
            return false
        }
        let prefix = text.prefix(4)
        return prefix.allSatisfy(\.isNumber)
    }
}
