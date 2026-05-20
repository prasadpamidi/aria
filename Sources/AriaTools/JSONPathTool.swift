import Aria
import Foundation

// MARK: - JSONPathTool

/// Query a JSON document with a dotted/bracketed path expression.
///
/// Supports a subset of JSONPath that covers the 95% case:
///   - `.foo` / `["foo"]` — object key
///   - `[0]` / `[12]` — array index
///   - `[*]` — array splat (returns each child as a JSON value)
///   - dotted chaining
///
/// Full JSONPath operators (filters, recursive descent, slices) are
/// out of scope — models that need richer querying should ask for
/// the raw JSON via `http_request` and parse client-side.
///
/// **Why this exists:** the agent often needs one nested field out
/// of a 200-line API response. Asking the model to extract by hand
/// burns tokens *and* gets the field wrong on long contexts. A
/// deterministic path query is more reliable and ~free token-wise.
public struct JSONPathTool: Tool {
    // MARK: Lifecycle

    public init() { }

    // MARK: Public

    public struct Input: Codable, Sendable {
        // MARK: Lifecycle

        public init(json: String, path: String) {
            self.json = json
            self.path = path
        }

        // MARK: Public

        public let json: String
        public let path: String
    }

    public struct Output: Codable, Sendable {
        // MARK: Lifecycle

        public init(value: String, matched: Bool) {
            self.value = value
            self.matched = matched
        }

        // MARK: Public

        /// JSON-encoded result of the query. Always a valid JSON
        /// value (`null` when the path didn't match anything).
        public let value: String
        public let matched: Bool
    }

    public static let name = "json_path"
    public static let description = """
    Extract a value from a JSON document using a path expression.

    Examples:
      path = ".items[0].name"        — first item's name
      path = ".weather.temperature"   — nested field
      path = ".tags[*]"               — every element of an array

    Returns the matched value JSON-encoded, or null when no match. \
    Use after http_request to pull out the one field you need without \
    having to re-read the full response.
    """

    public static var inputSchema: JSONSchema {
        .object(
            properties: [
                "json": .string(description: "The JSON document to query, as text."),
                "path": .string(description: "Path expression. See description for syntax."),
            ],
            required: ["json", "path"]
        )
    }

    public func call(_ input: Input, context _: ToolContext) async throws -> Output {
        guard let data = input.json.data(using: .utf8) else {
            throw JSONPathToolError.invalidJSON
        }
        let document: Any
        do {
            document = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw JSONPathToolError.invalidJSON
        }
        let segments = try Self.parsePath(input.path)
        let resolved = Self.resolve(document, segments: segments)
        guard let resolved else {
            return Output(value: "null", matched: false)
        }
        let resultData = try JSONSerialization.data(
            withJSONObject: resolved,
            options: [.fragmentsAllowed, .sortedKeys]
        )
        let resultText = String(data: resultData, encoding: .utf8) ?? "null"
        return Output(value: resultText, matched: true)
    }

    // MARK: Private

    /// Path segment vocabulary. `splat` is the only operator that
    /// can return multiple values (mapped to an array in the final
    /// result).
    private enum Segment: Equatable {
        case key(String)
        case index(Int)
        case splat
    }

    private static func parsePath(_ raw: String) throws -> [Segment] {
        var segments: [Segment] = []
        var current = ""
        var inBrackets = false
        let chars = Array(raw)
        var i = 0

        func flushCurrent() throws {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                current = ""
                return
            }
            if trimmed == "*" {
                segments.append(.splat)
            } else if let index = Int(trimmed) {
                segments.append(.index(index))
            } else {
                let unquoted = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                segments.append(.key(unquoted))
            }
            current = ""
        }

        while i < chars.count {
            let char = chars[i]
            switch char {
            case ".":
                if !inBrackets {
                    try flushCurrent()
                } else {
                    current.append(char)
                }
            case "[":
                if !inBrackets {
                    try flushCurrent()
                    inBrackets = true
                } else {
                    current.append(char)
                }
            case "]":
                if inBrackets {
                    try flushCurrent()
                    inBrackets = false
                } else {
                    throw JSONPathToolError.invalidPath
                }
            default:
                current.append(char)
            }
            i += 1
        }
        if inBrackets {
            throw JSONPathToolError.invalidPath
        }
        try flushCurrent()
        return segments
    }

    private static func resolve(_ value: Any?, segments: [Segment]) -> Any? {
        guard let value else {
            return nil
        }
        guard let head = segments.first else {
            return value
        }
        let tail = Array(segments.dropFirst())

        switch head {
        case let .key(key):
            guard let dict = value as? [String: Any] else {
                return nil
            }
            return self.resolve(dict[key], segments: tail)

        case let .index(index):
            guard let array = value as? [Any], index >= 0, index < array.count else {
                return nil
            }
            return self.resolve(array[index], segments: tail)

        case .splat:
            guard let array = value as? [Any] else {
                return nil
            }
            return array.compactMap { self.resolve($0, segments: tail) }
        }
    }
}

// MARK: - JSONPathToolError

public enum JSONPathToolError: LocalizedError {
    case invalidJSON
    case invalidPath

    // MARK: Public

    public var errorDescription: String? {
        switch self {
        case .invalidJSON: "The provided text is not valid JSON."
        case .invalidPath: "The path expression is malformed."
        }
    }
}
