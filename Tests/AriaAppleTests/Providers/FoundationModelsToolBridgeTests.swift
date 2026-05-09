#if canImport(FoundationModels) && (os(iOS) || os(macOS) || os(watchOS) || os(tvOS) || os(visionOS))

    import Foundation
    import FoundationModels
    import XCTest
    @testable import Aria
    @testable import AriaApple

    // MARK: - Test fixtures

    @available(iOS 26.0, macOS 26.0, *)
    private struct CurrentTimeTool: Aria.Tool {
        struct Input: Codable {
            let timezone: String?
        }

        struct Output: Codable {
            let iso8601: String
        }

        static let name = "current_time"
        static let description = "Returns the current time."

        static var inputSchema: JSONSchema {
            .object(properties: ["timezone": .string()], required: [])
        }

        func call(_ input: Input, context _: ToolContext) async throws -> Output {
            // Deterministic output for testing.
            _ = input.timezone
            return Output(iso8601: "2026-05-09T12:00:00Z")
        }
    }

    // MARK: - Schema translator

    @available(iOS 26.0, macOS 26.0, *)
    final class FoundationModelsSchemaTranslatorTests: XCTestCase {
        func testStringSchemaProducesGenerationSchema() throws {
            let schema = try FoundationModelsSchemaTranslator.generationSchema(
                forTool: "say",
                description: nil,
                inputSchema: .string()
            )
            // GenerationSchema is opaque; we just verify construction succeeds
            // and renders a non-empty debug description.
            XCTAssertFalse(schema.debugDescription.isEmpty)
        }

        func testObjectSchemaWithRequiredAndOptionalFields() throws {
            let schema = try FoundationModelsSchemaTranslator.generationSchema(
                forTool: "weather",
                description: "Get the weather",
                inputSchema: .object(
                    properties: [
                        "city": .string(description: "City name"),
                        "units": .string(enumValues: ["metric", "imperial"])
                    ],
                    required: ["city"]
                )
            )
            XCTAssertFalse(schema.debugDescription.isEmpty)
        }

        func testArrayOfObjectsRoundTrips() throws {
            let schema = try FoundationModelsSchemaTranslator.generationSchema(
                forTool: "add_items",
                description: nil,
                inputSchema: .object(
                    properties: [
                        "items": .array(
                            items: .object(
                                properties: ["name": .string(), "qty": .integer()],
                                required: ["name"]
                            )
                        )
                    ],
                    required: ["items"]
                )
            )
            XCTAssertFalse(schema.debugDescription.isEmpty)
        }

        func testOneOfSchema() throws {
            let schema = try FoundationModelsSchemaTranslator.generationSchema(
                forTool: "value",
                description: nil,
                inputSchema: .oneOf([.string(), .integer()])
            )
            XCTAssertFalse(schema.debugDescription.isEmpty)
        }
    }

    // MARK: - Bridge tool

    @available(iOS 26.0, macOS 26.0, *)
    final class AriaBridgeToolTests: XCTestCase {
        func testBridgeInvokesUnderlyingToolAndEmitsExecutedEvent() async throws {
            let underlying = AnyTool(CurrentTimeTool())
            let receivedEvents = ReceivedEvents()
            let bridge = try AriaBridgeTool(ariaTool: underlying) { event in
                receivedEvents.append(event)
            }

            let arguments = try GeneratedContent(json: #"{"timezone": "UTC"}"#)
            let result = try await bridge.call(arguments: arguments)

            // The tool returned its JSON-encoded Output for the model.
            XCTAssertTrue(result.contains("\"iso8601\""))

            // Exactly one toolCallExecuted event should have fired.
            let events = receivedEvents.snapshot()
            XCTAssertEqual(events.count, 1)
            guard case let .toolCallExecuted(call, execResult) = events[0] else {
                XCTFail("Expected toolCallExecuted event, got \(events[0])")
                return
            }
            XCTAssertEqual(call.name, "current_time")
            XCTAssertEqual(call.arguments, .object(["timezone": .string("UTC")]))
            XCTAssertFalse(execResult.isError)
        }

        func testBridgeSurfaceErrorWhenToolThrows() async throws {
            let throwingTool = AnyTool(
                definition: ToolDefinition(
                    name: "boom",
                    description: "Always throws",
                    inputSchema: .object(properties: [:])
                ),
                invoke: { _, _ in
                    throw NSError(domain: "test", code: 1)
                }
            )
            let receivedEvents = ReceivedEvents()
            let bridge = try AriaBridgeTool(ariaTool: throwingTool) { event in
                receivedEvents.append(event)
            }

            let arguments = try GeneratedContent(json: "{}")
            let result = try await bridge.call(arguments: arguments)

            // Error rendered as JSON for the model.
            XCTAssertTrue(result.contains("\"error\""))

            let events = receivedEvents.snapshot()
            guard case let .toolCallExecuted(_, execResult) = events.first else {
                XCTFail("Expected toolCallExecuted event")
                return
            }
            XCTAssertTrue(execResult.isError)
        }
    }

    // MARK: - Helpers

    /// Lock-protected event recorder for tests.
    ///
    /// The bridge calls back synchronously through a `@Sendable
    /// (ProviderEvent) -> Void` closure, so the recorder must record
    /// synchronously too. An actor here would force a `Task { ... }`
    /// hop, racing the assertions immediately following `bridge.call`.
    private final class ReceivedEvents: @unchecked Sendable {
        // MARK: Internal

        func append(_ event: ProviderEvent) {
            self.lock.lock()
            defer { self.lock.unlock() }
            self.storage.append(event)
        }

        func snapshot() -> [ProviderEvent] {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.storage
        }

        // MARK: Private

        private let lock = NSLock()
        private var storage: [ProviderEvent] = []
    }

#endif
