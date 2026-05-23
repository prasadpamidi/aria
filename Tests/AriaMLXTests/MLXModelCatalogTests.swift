#if ARIA_MLX
    #if canImport(MLXLMCommon)
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
                let entry = MLXModelCatalog.entry(for: "mlx-community/Qwen3.5-4B-MLX-4bit")
                XCTAssertNotNil(entry)
                XCTAssertEqual(entry?.family, "qwen3.5-vl")
                XCTAssertTrue(entry?.supportsTools ?? false)
                XCTAssertTrue(entry?.supportsVision ?? false)
            }

            func testEntryLookupReturnsNilForUnknownId() {
                XCTAssertNil(MLXModelCatalog.entry(for: "nonexistent/model"))
            }

            func testCapabilitiesAreCodable() throws {
                let original = MLXModelCapabilities.qwen35MLX4B4bit
                let data = try JSONEncoder().encode(original)
                let decoded = try JSONDecoder().decode(MLXModelCapabilities.self, from: data)
                XCTAssertEqual(decoded, original)
            }
        }
    #endif
#endif
