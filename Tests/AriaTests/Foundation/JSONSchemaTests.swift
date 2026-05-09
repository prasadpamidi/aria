import Foundation
import XCTest
@testable import Aria

final class JSONSchemaTests: XCTestCase {
    func testStringSchemaEncoding() throws {
        let schema = JSONSchema.string(description: "A name", enumValues: ["a", "b"])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(schema)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertTrue(json.contains("\"type\":\"string\""))
        XCTAssertTrue(json.contains("\"description\":\"A name\""))
        XCTAssertTrue(json.contains("\"enum\":[\"a\",\"b\"]"))
    }

    func testObjectSchemaRoundTrip() throws {
        let schema = JSONSchema.object(
            properties: [
                "city": .string(description: "City name"),
                "units": .string(description: "Units", enumValues: ["metric", "imperial"])
            ],
            required: ["city", "units"],
            description: "Weather query"
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(schema)
        let decoded = try JSONDecoder().decode(JSONSchema.self, from: data)
        XCTAssertEqual(schema, decoded)
    }

    func testNestedArraySchema() throws {
        let schema = JSONSchema.array(
            items: .object(
                properties: ["id": .integer()],
                required: ["id"]
            )
        )
        let encoder = JSONEncoder()
        let data = try encoder.encode(schema)
        let decoded = try JSONDecoder().decode(JSONSchema.self, from: data)
        XCTAssertEqual(schema, decoded)
    }

    func testOneOfSchema() throws {
        let schema = JSONSchema.oneOf([
            .string(),
            .integer()
        ])
        let encoder = JSONEncoder()
        let data = try encoder.encode(schema)
        let decoded = try JSONDecoder().decode(JSONSchema.self, from: data)
        XCTAssertEqual(schema, decoded)
    }

    func testSchemaToJSONValueWireFormat() throws {
        let schema = JSONSchema.string(description: "name")
        let value = try schema.toJSONValue()

        guard case let .object(dict) = value else {
            XCTFail("Expected object")
            return
        }
        XCTAssertEqual(dict["type"], .string("string"))
        XCTAssertEqual(dict["description"], .string("name"))
    }
}
