import Aria
import Foundation

// MARK: - CalculatorTool

/// Evaluates arithmetic expressions safely without letting the model
/// try to compute them itself (small models get this wrong
/// constantly). Backed by `NSExpression` on Apple platforms, which
/// handles arithmetic, parentheses, percent, sqrt/abs/min/max,
/// modulo, exponent, and `pi` / `e`. On Linux we fall back to a
/// minimal shunting-yard parser so the cross-platform contract holds.
///
/// **Why not let the model do math:** even GPT-4-class models get
/// long-precision arithmetic and decimal rounding wrong in
/// streaming responses. A 5-line tool that evaluates an expression
/// deterministically is more reliable than every "let's compute this
/// step by step" CoT detour.
public struct CalculatorTool: Tool {
    // MARK: Lifecycle

    public init() { }

    // MARK: Public

    public struct Input: Codable, Sendable {
        // MARK: Lifecycle

        public init(expression: String) {
            self.expression = expression
        }

        // MARK: Public

        public let expression: String
    }

    public struct Output: Codable, Sendable {
        // MARK: Lifecycle

        public init(result: Double, formatted: String) {
            self.result = result
            self.formatted = formatted
        }

        // MARK: Public

        public let result: Double
        public let formatted: String
    }

    public static let name = "calculator"
    public static let description = """
    Evaluate an arithmetic expression and return the numeric result.

    Supports +, -, *, /, parentheses, %, ^, abs(x), sqrt(x), min(a,b), \
    max(a,b), and the constants pi and e. Use this any time the user \
    asks for an exact number you'd otherwise have to compute mentally.
    """

    public static var inputSchema: JSONSchema {
        .object(
            properties: [
                "expression": .string(
                    description: "Arithmetic expression, e.g. \"(3.5 * 2) + sqrt(16)\""
                ),
            ],
            required: ["expression"]
        )
    }

    public func call(_ input: Input, context _: ToolContext) async throws -> Output {
        let cleaned = input.expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            throw CalculatorToolError.emptyExpression
        }
        #if canImport(Darwin)
            return try Self.evaluateWithNSExpression(cleaned)
        #else
            return try Self.evaluateMinimal(cleaned)
        #endif
    }

    // MARK: Private

    #if canImport(Darwin)
        /// `NSExpression` accepts the standard math forms plus a
        /// small built-in function vocabulary. We pre-rewrite a
        /// couple of human-friendly syntaxes (^ → **, `pi`/`e` →
        /// constants) so models don't have to know the NSExpression-
        /// specific spelling.
        private static func evaluateWithNSExpression(_ raw: String) throws -> Output {
            var expr = raw
                .replacingOccurrences(of: "^", with: "**")
                .replacingOccurrences(of: "pi", with: "\(Double.pi)", options: .caseInsensitive)
            // Replace standalone `e` (not part of `1e9` style
            // scientific notation) with Euler's number.
            expr = expr.replacingOccurrences(
                of: #"(?<![0-9])e(?![0-9])"#,
                with: "\(M_E)",
                options: .regularExpression
            )
            // Promote bare integer literals to doubles. NSExpression
            // does integer math when both operands look like
            // integers — `7 / 2` returns 3, not 3.5 — which
            // surprises every model that asks the calculator for a
            // fractional answer. Appending `.0` to integer-only
            // tokens (skipping decimals and scientific-notation
            // exponents) forces double arithmetic throughout.
            expr = expr.replacingOccurrences(
                of: #"(?<![0-9eE.])\d+(?![0-9.eE])"#,
                with: "$0.0",
                options: .regularExpression
            )
            let expression = NSExpression(format: expr)
            guard let value = expression.expressionValue(with: nil, context: nil) as? NSNumber else {
                throw CalculatorToolError.evaluationFailed
            }
            let result = value.doubleValue
            return Output(result: result, formatted: Self.format(result))
        }
    #endif

    /// Pure-Swift fallback so Linux consumers still get a working
    /// tool. Only +-*/ and parentheses — enough for the most common
    /// model-fired requests. Apps that need richer Linux support can
    /// substitute their own calculator tool.
    private static func evaluateMinimal(_ raw: String) throws -> Output {
        // Linux/non-Darwin path. Use a tiny recursive-descent parser.
        var parser = MinimalCalcParser(raw)
        let value = try parser.parseExpression()
        guard parser.isAtEnd else {
            throw CalculatorToolError.evaluationFailed
        }
        return Output(result: value, formatted: Self.format(value))
    }

    private static func format(_ value: Double) -> String {
        // Trim trailing zeros: 42.0 → "42", 3.14000 → "3.14".
        if value.isFinite, value.rounded() == value, abs(value) < 1e16 {
            return String(format: "%g", value)
        }
        return String(value)
    }
}

// MARK: - MinimalCalcParser

/// Recursive-descent expression parser for the Linux fallback path.
/// Intentionally small — Darwin consumers go through NSExpression.
private struct MinimalCalcParser {
    // MARK: Lifecycle

    init(_ source: String) {
        self.chars = Array(source.replacingOccurrences(of: " ", with: ""))
    }

    // MARK: Internal

    var isAtEnd: Bool {
        self.index >= self.chars.count
    }

    mutating func parseExpression() throws -> Double {
        var value = try self.parseTerm()
        while let op = self.peek(), op == "+" || op == "-" {
            self.advance()
            let rhs = try self.parseTerm()
            value = op == "+" ? value + rhs : value - rhs
        }
        return value
    }

    // MARK: Private

    private let chars: [Character]
    private var index = 0

    private mutating func parseTerm() throws -> Double {
        var value = try self.parseFactor()
        while let op = self.peek(), op == "*" || op == "/" {
            self.advance()
            let rhs = try self.parseFactor()
            value = op == "*" ? value * rhs : value / rhs
        }
        return value
    }

    private mutating func parseFactor() throws -> Double {
        if self.peek() == "(" {
            self.advance()
            let value = try self.parseExpression()
            guard self.peek() == ")" else {
                throw CalculatorToolError.evaluationFailed
            }
            self.advance()
            return value
        }
        var digits = ""
        while let char = self.peek(), char.isNumber || char == "." || char == "-" && digits.isEmpty {
            digits.append(char)
            self.advance()
        }
        guard let value = Double(digits) else {
            throw CalculatorToolError.evaluationFailed
        }
        return value
    }

    private func peek() -> Character? {
        self.index < self.chars.count ? self.chars[self.index] : nil
    }

    private mutating func advance() {
        self.index += 1
    }
}

// MARK: - CalculatorToolError

public enum CalculatorToolError: LocalizedError {
    case emptyExpression
    case evaluationFailed

    // MARK: Public

    public var errorDescription: String? {
        switch self {
        case .emptyExpression: "Expression is empty."
        case .evaluationFailed: "Could not evaluate the expression."
        }
    }
}
