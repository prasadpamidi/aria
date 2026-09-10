import Aria
import Foundation

// MARK: - TabularExtraction

/// Finds the row set inside an arbitrary tool result.
///
/// Tools return whatever shape their author chose: a bare array, an
/// envelope like `{"items": [...]}`, something nested two levels down,
/// or a JSON string that has to be decoded first. A chart needs
/// `[[String: JSONValue]]`, and the model must not be the thing that
/// reshapes it — asking it to transcribe rows is asking it to invent
/// them.
///
/// So the host looks. The rules are deliberately dull and predictable,
/// because a surprising rule here produces a chart of the wrong data,
/// which is worse than no chart.
public enum TabularExtraction {
    // MARK: Public

    /// Where the rows came from, and what was left out.
    public struct Extraction: Equatable, Sendable {
        public let rows: [[String: JSONValue]]
        /// Key path the rows were found at; empty when the result was
        /// itself an array. Useful for telling a user *what* was
        /// charted when a result had several candidate arrays.
        public let path: [String]
        /// Original row count when rows were dropped, else `nil`.
        public let truncatedFrom: Int?
    }

    public static let defaultMaximumRows = 2000

    /// Extract the most plausible row set, or `nil` if there isn't one.
    ///
    /// - Parameter maximumRows: Charts of ten thousand points are
    ///   unreadable and slow to draw. Excess rows are dropped from the
    ///   end, and `extractDetailed` reports that it happened.
    public static func rows(
        from value: JSONValue,
        maximumRows: Int = TabularExtraction.defaultMaximumRows
    ) -> [[String: JSONValue]]? {
        self.extractDetailed(from: value, maximumRows: maximumRows)?.rows
    }

    /// As `rows(from:)`, but reports where the rows were found and
    /// whether any were dropped — the caller usually wants to say so.
    public static func extractDetailed(
        from value: JSONValue,
        maximumRows: Int = TabularExtraction.defaultMaximumRows
    ) -> Extraction? {
        guard let found = self.search(value, depth: 0, path: []) else {
            return nil
        }
        let truncated = found.rows.count > maximumRows
        return Extraction(
            rows: truncated ? Array(found.rows.prefix(maximumRows)) : found.rows,
            path: found.path,
            truncatedFrom: truncated ? found.rows.count : nil
        )
    }

    // MARK: Private

    private struct Found {
        let rows: [[String: JSONValue]]
        let path: [String]
    }

    /// Keys checked first when several arrays are present. A result
    /// with both `items` and `warnings` should chart the items.
    private static let preferredKeys = [
        "rows", "items", "data", "results", "records", "series", "values", "entries", "points",
    ]

    /// How deep to look. Two levels covers `{"data": {"items": [...]}}`
    /// without wandering into unrelated nested structures.
    private static let maximumDepth = 3

    private static func search(_ value: JSONValue, depth: Int, path: [String]) -> Found? {
        guard depth <= self.maximumDepth else {
            return nil
        }
        switch value {
        case let .array(items):
            return self.rowsFromArray(items).map { Found(rows: $0, path: path) }

        case let .string(text):
            // A tool that returns JSON as a string is common enough to
            // handle, but only at the top: decoding strings found deep
            // inside a payload would be guessing.
            guard depth == 0,
                  let data = text.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(JSONValue.self, from: data) else {
                return nil
            }
            return self.search(decoded, depth: depth + 1, path: path)

        case let .object(fields):
            // Preferred keys first, in order, so the choice is stable
            // rather than dependent on dictionary ordering.
            for key in Self.preferredKeys {
                guard let child = fields[key] else {
                    continue
                }
                if case let .array(items) = child, let rows = self.rowsFromArray(items) {
                    return Found(rows: rows, path: path + [key])
                }
            }
            // Then any array-valued key, sorted for determinism.
            for key in fields.keys.sorted() {
                if case let .array(items) = fields[key], let rows = self.rowsFromArray(items) {
                    return Found(rows: rows, path: path + [key])
                }
            }
            // Then recurse into objects, also sorted.
            for key in fields.keys.sorted() {
                guard let child = fields[key], case .object = child else {
                    continue
                }
                if let found = self.search(child, depth: depth + 1, path: path + [key]) {
                    return found
                }
            }
            return nil

        default:
            return nil
        }
    }

    /// An array is a row set only if it is non-empty and every element
    /// is an object. A mixed array is not a table, and charting the
    /// object-shaped subset of one would silently drop data.
    private static func rowsFromArray(_ items: [JSONValue]) -> [[String: JSONValue]]? {
        guard !items.isEmpty else {
            return nil
        }
        var rows: [[String: JSONValue]] = []
        rows.reserveCapacity(items.count)
        for item in items {
            guard case let .object(fields) = item else {
                return nil
            }
            rows.append(fields)
        }
        return rows
    }
}
