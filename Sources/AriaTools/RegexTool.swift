import Aria
import Foundation

// MARK: - RegexTool

/// Match, extract, or replace text using an ICU regular expression.
///
/// Three modes via the `operation` field:
///   - `match`   — return whether the pattern matches and, if so,
///                  the first match's range + matched text.
///   - `findAll` — return every non-overlapping match (text + capture
///                  groups) as a list.
///   - `replace` — substitute all matches with the `replacement`
///                  template ($1, $2 for capture-group backrefs).
///
/// **Why this exists**: extracting "the date in this paragraph" or
/// "every URL in this list" via the model burns tokens and gets
/// edge cases wrong. A regex tool is exact.
public struct RegexTool: Tool {
    // MARK: Lifecycle

    public init() { }

    // MARK: Public

    public struct Input: Codable, Sendable {
        // MARK: Lifecycle

        public init(
            operation: String,
            text: String,
            pattern: String,
            replacement: String? = nil,
            caseInsensitive: Bool? = nil
        ) {
            self.operation = operation
            self.text = text
            self.pattern = pattern
            self.replacement = replacement
            self.caseInsensitive = caseInsensitive
        }

        // MARK: Public

        public let operation: String
        public let text: String
        public let pattern: String
        public let replacement: String?
        public let caseInsensitive: Bool?
    }

    public struct Output: Codable, Sendable {
        // MARK: Lifecycle

        public init(matched: Bool, matches: [Match], replaced: String?) {
            self.matched = matched
            self.matches = matches
            self.replaced = replaced
        }

        // MARK: Public

        public struct Match: Codable, Sendable {
            // MARK: Lifecycle

            public init(text: String, groups: [String]) {
                self.text = text
                self.groups = groups
            }

            // MARK: Public

            public let text: String
            public let groups: [String]
        }

        public let matched: Bool
        /// For `match` and `findAll`: each entry's `text` is the
        /// whole match; `groups` is the captured-group values in
        /// order. Empty for `replace`.
        public let matches: [Match]
        /// Set for `replace`: the text after substitution. Nil for
        /// `match` / `findAll`.
        public let replaced: String?
    }

    public static let name = "regex"
    public static let description = """
    Match, extract, or replace text with a regular expression.

    Use 'operation': "match" for yes/no + first match, "findAll" for \
    every match (with capture groups), or "replace" with a replacement \
    template. Patterns follow ICU regex syntax.
    """

    public static var inputSchema: JSONSchema {
        .object(
            properties: [
                "operation": .string(
                    description: "Which mode to run.",
                    enumValues: ["match", "findAll", "replace"]
                ),
                "text": .string(description: "Input text to search."),
                "pattern": .string(description: "ICU regex pattern."),
                "replacement": .string(
                    description: "Replacement template for 'replace' mode. Use $1, $2 for capture groups."
                ),
                "caseInsensitive": .boolean(description: "Match case-insensitively. Defaults to false."),
            ],
            required: ["operation", "text", "pattern"]
        )
    }

    public func call(_ input: Input, context _: ToolContext) async throws -> Output {
        let options: NSRegularExpression.Options = input.caseInsensitive == true
            ? [.caseInsensitive]
            : []
        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: input.pattern, options: options)
        } catch {
            throw RegexToolError.invalidPattern(error.localizedDescription)
        }
        let range = NSRange(input.text.startIndex..., in: input.text)

        switch input.operation.lowercased() {
        case "match":
            return Self.runMatch(regex: regex, text: input.text, range: range, first: true)

        case "findall":
            return Self.runMatch(regex: regex, text: input.text, range: range, first: false)

        case "replace":
            let template = input.replacement ?? ""
            let replaced = regex.stringByReplacingMatches(
                in: input.text,
                options: [],
                range: range,
                withTemplate: template
            )
            let didMatch = regex.firstMatch(in: input.text, options: [], range: range) != nil
            return Output(
                matched: didMatch,
                matches: [],
                replaced: replaced
            )

        default:
            throw RegexToolError.unknownOperation(input.operation)
        }
    }

    // MARK: Private

    private static func runMatch(
        regex: NSRegularExpression,
        text: String,
        range: NSRange,
        first: Bool
    ) -> Output {
        let results = first
            ? regex.firstMatch(in: text, options: [], range: range).map { [$0] } ?? []
            : regex.matches(in: text, options: [], range: range)
        let matches = results.map { result -> Output.Match in
            let whole = Self.substring(text, nsRange: result.range)
            var groups: [String] = []
            for i in 1..<result.numberOfRanges {
                groups.append(Self.substring(text, nsRange: result.range(at: i)))
            }
            return Output.Match(text: whole, groups: groups)
        }
        return Output(matched: !matches.isEmpty, matches: matches, replaced: nil)
    }

    private static func substring(_ text: String, nsRange: NSRange) -> String {
        guard nsRange.location != NSNotFound,
              let range = Range(nsRange, in: text) else {
            return ""
        }
        return String(text[range])
    }
}

// MARK: - RegexToolError

public enum RegexToolError: LocalizedError {
    case invalidPattern(String)
    case unknownOperation(String)

    // MARK: Public

    public var errorDescription: String? {
        switch self {
        case let .invalidPattern(detail):
            "Invalid regex pattern: \(detail)"
        case let .unknownOperation(name):
            "Unknown operation \"\(name)\". Use match, findAll, or replace."
        }
    }
}
