#if ARIA_MLX
    #if canImport(MLXLMCommon)
        import XCTest
        @testable import AriaMLX

        @MainActor
        final class MLXModelManagerTests: XCTestCase {
            func testCatalogIncludesGemma4Variants() {
                let ids = MLXModelCatalog.defaults.map(\.id)
                XCTAssertTrue(ids.contains("mlx-community/gemma-4-e2b-it-4bit"))
                XCTAssertTrue(ids.contains("mlx-community/gemma-4-e4b-it-4bit"))
            }

            func testGemma4EntriesAreVisionModels() {
                for entry in MLXModelCatalog.defaults where entry.family == "gemma-4" {
                    XCTAssertEqual(entry.kind, .vision)
                    XCTAssertTrue(entry.supportsVision)
                }
            }

            func testManagerStartsWithNoActiveModel() {
                let manager = MLXModelManager()
                XCTAssertNil(manager.activeModelID)
                XCTAssertNil(manager.activeCapabilities)
                XCTAssertNil(manager.makeProvider())
            }

            func testSetActiveModelLooksUpCatalog() {
                let manager = MLXModelManager()
                manager.setActiveModel(id: "mlx-community/gemma-4-e2b-it-4bit")
                XCTAssertEqual(manager.activeModelID, "mlx-community/gemma-4-e2b-it-4bit")
                XCTAssertEqual(manager.activeCapabilities?.family, "gemma-4")
            }

            func testManagerAcceptsCustomCatalog() {
                let custom = MLXModelCapabilities(
                    id: "consumer/custom-7b-4bit",
                    displayName: "Custom 7B",
                    family: "custom",
                    approximateDiskBytes: 4_000_000_000,
                    contextWindow: 4096,
                    supportsTools: false
                )
                let manager = MLXModelManager(catalog: [custom])
                XCTAssertEqual(manager.catalog.count, 1)
                XCTAssertEqual(manager.entry(for: custom.id)?.displayName, "Custom 7B")
            }
        }

    #endif
#endif
