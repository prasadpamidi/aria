import XCTest
@testable import AriaMLX

final class MLXModelCatalogTests: XCTestCase {
    func testDefaultsAreNonEmptyAndUnique() {
        let defaults = MLXModelCatalog.defaults
        XCTAssertFalse(defaults.isEmpty)
        let ids = defaults.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "Catalog ids must be unique")
    }

    func testEntryLookupReturnsCuratedCapabilities() {
        let entry = MLXModelCatalog.entry(for: "mlx-community/Qwen2.5-1.5B-Instruct-4bit")
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.family, "qwen2.5")
        XCTAssertTrue(entry?.supportsTools ?? false)
    }

    func testEntryLookupReturnsNilForUnknownId() {
        XCTAssertNil(MLXModelCatalog.entry(for: "nonexistent/model"))
    }

    func testCapabilitiesAreCodable() throws {
        let original = MLXModelCapabilities.qwen25Instruct4bit
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MLXModelCapabilities.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}
