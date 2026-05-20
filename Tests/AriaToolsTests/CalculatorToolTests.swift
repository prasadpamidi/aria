import Aria
import AriaTools
import XCTest

final class CalculatorToolTests: XCTestCase {
    func testBasicArithmetic() async throws {
        let tool = CalculatorTool()
        let output = try await tool.call(
            CalculatorTool.Input(expression: "2 + 3 * 4"),
            context: ToolContext()
        )
        XCTAssertEqual(output.result, 14)
        XCTAssertEqual(output.formatted, "14")
    }

    func testParenthesesAffectPrecedence() async throws {
        let tool = CalculatorTool()
        let output = try await tool.call(
            CalculatorTool.Input(expression: "(2 + 3) * 4"),
            context: ToolContext()
        )
        XCTAssertEqual(output.result, 20)
    }

    func testDivisionProducesDouble() async throws {
        let tool = CalculatorTool()
        let output = try await tool.call(
            CalculatorTool.Input(expression: "7 / 2"),
            context: ToolContext()
        )
        XCTAssertEqual(output.result, 3.5)
    }

    func testCaretIsRewrittenToExponent() async throws {
        // The tool maps `^` → `**` so model-natural exponent syntax
        // works without authors having to know NSExpression's spelling.
        let tool = CalculatorTool()
        let output = try await tool.call(
            CalculatorTool.Input(expression: "2 ^ 10"),
            context: ToolContext()
        )
        XCTAssertEqual(output.result, 1024)
    }

    func testSqrtBuiltIn() async throws {
        let tool = CalculatorTool()
        let output = try await tool.call(
            CalculatorTool.Input(expression: "sqrt(16)"),
            context: ToolContext()
        )
        XCTAssertEqual(output.result, 4)
    }

    func testPiConstant() async throws {
        let tool = CalculatorTool()
        let output = try await tool.call(
            CalculatorTool.Input(expression: "pi * 2"),
            context: ToolContext()
        )
        XCTAssertEqual(output.result, .pi * 2, accuracy: 1e-12)
    }

    func testEmptyExpressionThrows() async {
        let tool = CalculatorTool()
        do {
            _ = try await tool.call(
                CalculatorTool.Input(expression: "   "),
                context: ToolContext()
            )
            XCTFail("expected throw")
        } catch CalculatorToolError.emptyExpression {
            // expected
        } catch {
            XCTFail("unexpected: \(error)")
        }
    }

    func testFormattedTrimsTrailingZeros() async throws {
        let tool = CalculatorTool()
        let output = try await tool.call(
            CalculatorTool.Input(expression: "100 / 4"),
            context: ToolContext()
        )
        XCTAssertEqual(output.result, 25)
        XCTAssertEqual(output.formatted, "25")
    }
}
