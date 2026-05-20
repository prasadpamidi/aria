import Aria
import AriaTools
import XCTest

final class JSONPathToolTests: XCTestCase {
    // MARK: Internal

    func testDottedKeyAccess() async throws {
        let tool = JSONPathTool()
        let output = try await tool.call(
            JSONPathTool.Input(json: self.document, path: ".weather.temperature"),
            context: ToolContext()
        )
        XCTAssertEqual(output.value, "72")
        XCTAssertTrue(output.matched)
    }

    func testArrayIndexAccess() async throws {
        let tool = JSONPathTool()
        let output = try await tool.call(
            JSONPathTool.Input(json: self.document, path: ".items[0].name"),
            context: ToolContext()
        )
        XCTAssertEqual(output.value, "\"apple\"")
    }

    func testSplatReturnsArray() async throws {
        let tool = JSONPathTool()
        let output = try await tool.call(
            JSONPathTool.Input(json: self.document, path: ".tags[*]"),
            context: ToolContext()
        )
        XCTAssertEqual(output.value, "[\"one\",\"two\",\"three\"]")
    }

    func testSplatWithChildPath() async throws {
        let tool = JSONPathTool()
        let output = try await tool.call(
            JSONPathTool.Input(json: self.document, path: ".items[*].name"),
            context: ToolContext()
        )
        XCTAssertEqual(output.value, "[\"apple\",\"pear\"]")
    }

    func testMissingPathReturnsNullNotMatched() async throws {
        let tool = JSONPathTool()
        let output = try await tool.call(
            JSONPathTool.Input(json: self.document, path: ".weather.humidity"),
            context: ToolContext()
        )
        XCTAssertEqual(output.value, "null")
        XCTAssertFalse(output.matched)
    }

    func testInvalidJSONThrows() async {
        let tool = JSONPathTool()
        do {
            _ = try await tool.call(
                JSONPathTool.Input(json: "this is not json", path: ".x"),
                context: ToolContext()
            )
            XCTFail("expected throw")
        } catch JSONPathToolError.invalidJSON {
            // expected
        } catch {
            XCTFail("unexpected: \(error)")
        }
    }

    func testBracketKeyEquivalentToDottedKey() async throws {
        // `["weather"]` should resolve the same as `.weather`.
        let tool = JSONPathTool()
        let output = try await tool.call(
            JSONPathTool.Input(json: self.document, path: "[\"weather\"].condition"),
            context: ToolContext()
        )
        XCTAssertEqual(output.value, "\"sunny\"")
    }

    func testOutOfRangeIndexReturnsNull() async throws {
        let tool = JSONPathTool()
        let output = try await tool.call(
            JSONPathTool.Input(json: self.document, path: ".items[99].name"),
            context: ToolContext()
        )
        XCTAssertEqual(output.value, "null")
        XCTAssertFalse(output.matched)
    }

    // MARK: Private

    private let document = """
    {
      "weather": {
        "temperature": 72,
        "condition": "sunny"
      },
      "tags": ["one", "two", "three"],
      "items": [
        { "name": "apple", "qty": 3 },
        { "name": "pear", "qty": 1 }
      ]
    }
    """
}
