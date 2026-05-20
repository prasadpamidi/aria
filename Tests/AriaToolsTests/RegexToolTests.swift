import Aria
import AriaTools
import XCTest

final class RegexToolTests: XCTestCase {
    func testMatchReturnsFirstHit() async throws {
        let tool = RegexTool()
        let output = try await tool.call(
            RegexTool.Input(
                operation: "match",
                text: "Order #1234 shipped on 2026-05-19",
                pattern: #"#(\d+)"#,
                replacement: nil,
                caseInsensitive: nil
            ),
            context: ToolContext()
        )
        XCTAssertTrue(output.matched)
        XCTAssertEqual(output.matches.count, 1)
        XCTAssertEqual(output.matches[0].text, "#1234")
        XCTAssertEqual(output.matches[0].groups, ["1234"])
    }

    func testFindAllReturnsEveryHit() async throws {
        let tool = RegexTool()
        let output = try await tool.call(
            RegexTool.Input(
                operation: "findAll",
                text: "alice@example.com and bob@example.org and charlie@example.net",
                pattern: #"([\w]+)@([\w.]+)"#,
                replacement: nil,
                caseInsensitive: nil
            ),
            context: ToolContext()
        )
        XCTAssertEqual(output.matches.count, 3)
        XCTAssertEqual(output.matches.map(\.groups.first), ["alice", "bob", "charlie"])
        XCTAssertEqual(output.matches.map(\.groups.last), ["example.com", "example.org", "example.net"])
    }

    func testReplaceSubstitutesAllOccurrences() async throws {
        let tool = RegexTool()
        let output = try await tool.call(
            RegexTool.Input(
                operation: "replace",
                text: "1 cat, 2 cats, 3 cats",
                pattern: "cat",
                replacement: "dog",
                caseInsensitive: nil
            ),
            context: ToolContext()
        )
        XCTAssertEqual(output.replaced, "1 dog, 2 dogs, 3 dogs")
        XCTAssertTrue(output.matched)
    }

    func testReplaceWithCaptureGroupBackrefs() async throws {
        let tool = RegexTool()
        let output = try await tool.call(
            RegexTool.Input(
                operation: "replace",
                text: "John Smith, Jane Doe",
                pattern: #"(\w+) (\w+)"#,
                replacement: "$2 $1",
                caseInsensitive: nil
            ),
            context: ToolContext()
        )
        XCTAssertEqual(output.replaced, "Smith John, Doe Jane")
    }

    func testCaseInsensitiveFlag() async throws {
        let tool = RegexTool()
        let output = try await tool.call(
            RegexTool.Input(
                operation: "findAll",
                text: "Hello HELLO hello",
                pattern: "hello",
                replacement: nil,
                caseInsensitive: true
            ),
            context: ToolContext()
        )
        XCTAssertEqual(output.matches.count, 3)
    }

    func testInvalidPatternThrows() async {
        let tool = RegexTool()
        do {
            _ = try await tool.call(
                RegexTool.Input(
                    operation: "match",
                    text: "anything",
                    pattern: "[unclosed",
                    replacement: nil,
                    caseInsensitive: nil
                ),
                context: ToolContext()
            )
            XCTFail("expected throw")
        } catch RegexToolError.invalidPattern {
            // expected
        } catch {
            XCTFail("unexpected: \(error)")
        }
    }

    func testUnknownOperationThrows() async {
        let tool = RegexTool()
        do {
            _ = try await tool.call(
                RegexTool.Input(
                    operation: "garbage",
                    text: "x",
                    pattern: "x",
                    replacement: nil,
                    caseInsensitive: nil
                ),
                context: ToolContext()
            )
            XCTFail("expected throw")
        } catch RegexToolError.unknownOperation {
            // expected
        } catch {
            XCTFail("unexpected: \(error)")
        }
    }
}
