import Foundation
import XCTest
@testable import Aria

// MARK: - AdderTool

private struct AdderTool: Tool {
    struct Input: Codable {
        let lhs: Int
        let rhs: Int
    }

    struct Output: Codable {
        let sum: Int
    }

    static let name = "add"
    static let description = "Adds two integers"

    static var inputSchema: JSONSchema {
        .object(
            properties: [
                "lhs": .integer(),
                "rhs": .integer()
            ],
            required: ["lhs", "rhs"]
        )
    }

    func call(_ input: Input, context _: ToolContext) async throws -> Output {
        Output(sum: input.lhs + input.rhs)
    }
}

// MARK: - ThrowingTool

private struct ThrowingTool: Tool {
    struct Input: Codable {
        let value: String
    }

    struct Output: Codable { }

    struct Boom: Error { }

    static let name = "throwing"
    static let description = "Always throws"

    static var inputSchema: JSONSchema {
        .object(properties: ["value": .string()])
    }

    func call(_: Input, context _: ToolContext) async throws -> Output {
        throw Boom()
    }
}

// MARK: - ToolTests

final class ToolTests: XCTestCase {
    func testAnyToolDecodesInputAndEncodesOutput() async throws {
        let tool = AnyTool(AdderTool())
        XCTAssertEqual(tool.name, "add")

        let result = try await tool.invoke(
            .object(["lhs": .integer(2), "rhs": .integer(3)]),
            ToolContext()
        )

        XCTAssertEqual(result.objectValue?["sum"], .integer(5))
    }

    func testAnyToolSurfaceInvalidArgumentsError() async {
        let tool = AnyTool(AdderTool())
        do {
            _ = try await tool.invoke(
                .object(["lhs": .string("not-a-number")]),
                ToolContext()
            )
            XCTFail("Expected invalidToolArguments")
        } catch let error as AgentError {
            if case let .invalidToolArguments(name, _) = error {
                XCTAssertEqual(name, "add")
            } else {
                XCTFail("Expected invalidToolArguments, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testAnyToolWrapsThrownErrorAsToolExecutionFailed() async {
        let tool = AnyTool(ThrowingTool())
        do {
            _ = try await tool.invoke(.object(["value": .string("x")]), ToolContext())
            XCTFail("Expected toolExecutionFailed")
        } catch let error as AgentError {
            if case let .toolExecutionFailed(name, _) = error {
                XCTAssertEqual(name, "throwing")
            } else {
                XCTFail("Expected toolExecutionFailed, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testToolDefinitionContainsSchema() {
        let definition = AdderTool.definition
        XCTAssertEqual(definition.name, "add")
        XCTAssertEqual(definition.description, "Adds two integers")

        if case let .object(properties, required, _, _) = definition.inputSchema {
            XCTAssertEqual(Set(properties.keys), ["lhs", "rhs"])
            XCTAssertEqual(Set(required), ["lhs", "rhs"])
        } else {
            XCTFail("Expected object schema")
        }
    }

    func testAnyToolFromClosure() async throws {
        let tool = AnyTool(
            definition: ToolDefinition(
                name: "echo",
                description: "Echoes input",
                inputSchema: .object(properties: ["msg": .string()])
            ),
            invoke: { args, _ in args }
        )
        let result = try await tool.invoke(.object(["msg": .string("hi")]), ToolContext())
        XCTAssertEqual(result, .object(["msg": .string("hi")]))
    }
}
