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

            /// The tool-shape override is a new optional field, so
            /// payloads written before it existed must still decode.
            func testCapabilitiesDecodeWithoutToolShapeOverride() throws {
                let json = #"""
                {
                    "id": "acme/legacy-model",
                    "displayName": "Legacy",
                    "family": "legacy",
                    "kind": "textOnly",
                    "approximateDiskBytes": 1000,
                    "contextWindow": 4096,
                    "supportsTools": true,
                    "supportsVision": false,
                    "supportsReasoning": false,
                    "reliability": "medium",
                    "recommendedRAMGigabytes": 4
                }
                """#
                let decoded = try JSONDecoder().decode(
                    MLXModelCapabilities.self,
                    from: Data(json.utf8)
                )
                XCTAssertNil(decoded.requiresOpenAIToolShapeOverride)
                XCTAssertFalse(decoded.requiresOpenAIToolShape)
            }

            // MARK: LFM2.5

            func testLFM25EntriesAreInDefaults() {
                let ids = Set(MLXModelCatalog.defaults.map(\.id))
                for id in [
                    "mlx-community/LFM2.5-350M-6bit",
                    "mlx-community/LFM2.5-VL-450M-6bit",
                    "mlx-community/LFM2.5-1.2B-Instruct-4bit",
                    "mlx-community/LFM2.5-1.2B-Thinking-4bit",
                    "mlx-community/LFM2.5-VL-1.6B-4bit",
                ] {
                    XCTAssertTrue(ids.contains(id), "Missing catalog entry: \(id)")
                }
            }

            /// `MLXProvider` picks its parser by family prefix. A
            /// family string that accidentally matched `qwen` /
            /// `llama-3` / `gemma-4` would route LFM2.5 output into
            /// the wrong Aria-side stream parser instead of letting
            /// `mlx-swift-lm` parse the pythonic format.
            func testLFM25UsesBuiltInPythonicParsingNotAnAriaStreamParser() {
                XCTAssertEqual(Self.lfm25Entries.count, 5)
                for entry in Self.lfm25Entries {
                    XCTAssertEqual(entry.toolCallFormat, .lfm2, entry.id)
                    XCTAssertTrue(entry.supportsTools, entry.id)
                    XCTAssertFalse(entry.usesQwenToolFormat, entry.id)
                    XCTAssertFalse(entry.usesLlama3ToolFormat, entry.id)
                    XCTAssertFalse(entry.usesGemma4ToolFormat, entry.id)
                }
            }

            /// Only the explicitly named Thinking variant emits
            /// `<think>…</think>`. Flagging its siblings would flash
            /// the Thinking pill on every turn for models that stream
            /// their answer directly.
            func testOnlyThinkingVariantAdvertisesReasoning() {
                for entry in Self.lfm25Entries {
                    XCTAssertEqual(
                        entry.supportsReasoning,
                        entry.id.contains("Thinking"),
                        entry.id
                    )
                }
            }

            func testOnlyVL450MRequiresOpenAIToolShape() {
                for entry in Self.lfm25Entries {
                    XCTAssertEqual(
                        entry.requiresOpenAIToolShape,
                        entry.id.contains("VL-450M"),
                        "\(entry.id): the downloaded chat template decides this — VL-450M "
                            + "renders message.tool_calls, the other four render plain content"
                    )
                }
            }

            func testOnlyVLEntriesAreVisionKind() {
                for entry in Self.lfm25Entries {
                    let isVL = entry.id.contains("-VL-")
                    XCTAssertEqual(entry.kind, isVL ? .vision : .textOnly, entry.id)
                    XCTAssertEqual(entry.supportsVision, isVL, entry.id)
                }
            }

            // MARK: Regression guards

            /// The tool-shape override is opt-in. Families that relied
            /// on the previously purely-computed property must answer
            /// exactly as they did before it existed.
            func testToolShapeOverrideLeavesExistingFamiliesUnchanged() {
                XCTAssertTrue(MLXModelCapabilities.qwen35MLX4B4bit.requiresOpenAIToolShape)
                XCTAssertTrue(MLXModelCapabilities.llama32Instruct4bit.requiresOpenAIToolShape)
                XCTAssertTrue(MLXModelCapabilities.gemma4E2BInstruct4bit.requiresOpenAIToolShape)
                XCTAssertFalse(MLXModelCapabilities.qwen25Instruct1_5B4bit.requiresOpenAIToolShape)
                XCTAssertFalse(MLXModelCapabilities.gemma2Instruct4bit.requiresOpenAIToolShape)
            }

            /// `defaults` documents itself as "ordered roughly by RAM
            /// footprint", and the picker renders families in
            /// first-appearance order — so a mis-sorted insertion
            /// silently reshuffles the UI.
            func testDefaultsAreOrderedByRecommendedRAM() {
                let ram = MLXModelCatalog.defaults.map(\.recommendedRAMGigabytes)
                XCTAssertEqual(ram, ram.sorted(), "Catalog must stay sorted by recommended RAM")
            }

            // MARK: Private

            private static var lfm25Entries: [MLXModelCapabilities] {
                MLXModelCatalog.defaults.filter { $0.family == "lfm2.5" }
            }
        }
    #endif
#endif
