import Foundation
import XCTest
@testable import Aria

final class JSONValueTests: XCTestCase {
    func testCodableRoundTrip() throws {
        let original: JSONValue = .object([
            "name": .string("Aria"),
            "version": .integer(1),
            "score": .number(3.14),
            "active": .bool(true),
            "tags": .array([.string("a"), .string("b")]),
            "nullable": .null
        ])

        let data = try original.canonicalData()
        let roundTrip = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(roundTrip, original)
    }

    func testAccessors() {
        XCTAssertEqual(JSONValue.string("hi").stringValue, "hi")
        XCTAssertEqual(JSONValue.integer(42).integerValue, 42)
        XCTAssertEqual(JSONValue.number(2.5).numberValue, 2.5)
        XCTAssertEqual(JSONValue.integer(7).numberValue, 7.0)
        XCTAssertEqual(JSONValue.bool(true).boolValue, true)
        XCTAssertEqual(JSONValue.array([.integer(1)]).arrayValue?.count, 1)
        XCTAssertEqual(JSONValue.object(["x": .integer(1)]).objectValue?["x"], .integer(1))
        XCTAssertNil(JSONValue.null.stringValue)
    }

    func testLiteralConstruction() {
        let value: JSONValue = [
            "a": 1,
            "b": "text",
            "c": true,
            "d": 1.5,
            "e": nil,
            "f": [1, 2, 3]
        ]
        guard case let .object(dict) = value else {
            XCTFail("Expected object")
            return
        }
        XCTAssertEqual(dict["a"], .integer(1))
        XCTAssertEqual(dict["b"], .string("text"))
        XCTAssertEqual(dict["c"], .bool(true))
        XCTAssertEqual(dict["d"], .number(1.5))
        XCTAssertEqual(dict["e"], .null)
        XCTAssertEqual(dict["f"], .array([.integer(1), .integer(2), .integer(3)]))
    }

    func testEncodeDecodeCustomCodableType() throws {
        struct Item: Codable, Equatable {
            let name: String
            let count: Int
        }

        let item = Item(name: "widget", count: 3)
        let value = try JSONValue.encode(item)
        let decoded = try value.decode(Item.self)
        XCTAssertEqual(decoded, item)
    }

    func testIntegerVsNumberDecoding() throws {
        let intJSON = Data("42".utf8)
        let numJSON = Data("42.5".utf8)

        let intValue = try JSONDecoder().decode(JSONValue.self, from: intJSON)
        let numValue = try JSONDecoder().decode(JSONValue.self, from: numJSON)

        XCTAssertEqual(intValue, .integer(42))
        XCTAssertEqual(numValue, .number(42.5))
    }
}
