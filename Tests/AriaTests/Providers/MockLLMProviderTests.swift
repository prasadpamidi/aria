import Foundation
import XCTest
@testable import Aria
@testable import AriaTesting

final class MockLLMProviderTests: XCTestCase {
    // MARK: Internal

    func testStreamReplaysScriptedScene() async throws {
        let provider = MockLLMProvider(scenes: [.text("Hello, world.")])
        var collected: [ProviderEvent] = []

        for try await event in provider.stream(messages: [.user("hi")], tools: [], options: .init()) {
            collected.append(event)
        }

        guard collected.count == 3 else {
            XCTFail("Expected 3 events, got \(collected.count)")
            return
        }
        if case let .messageStart(messageId) = collected[0] {
            XCTAssertFalse(messageId.isEmpty)
        } else {
            XCTFail("Expected messageStart")
        }
        XCTAssertEqual(collected[1], .textDelta("Hello, world."))
        XCTAssertEqual(collected[2], .messageStop(.endTurn))
    }

    func testConsecutiveStreamCallsConsumeScenesInOrder() async throws {
        let provider = MockLLMProvider(scenes: [
            .text("first"),
            .text("second")
        ])

        let firstEvents = try await collect(provider.stream(messages: [], tools: [], options: .init()))
        let secondEvents = try await collect(provider.stream(messages: [], tools: [], options: .init()))

        XCTAssertTrue(firstEvents.contains(.textDelta("first")))
        XCTAssertTrue(secondEvents.contains(.textDelta("second")))
    }

    func testOutOfScenesThrowsExpectedError() async {
        let provider = MockLLMProvider(scenes: [])
        do {
            for try await _ in provider.stream(messages: [], tools: [], options: .init()) { }
            XCTFail("Expected outOfScenes error")
        } catch let error as MockLLMProviderError {
            XCTAssertEqual(error, .outOfScenes)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testInvocationsAreRecorded() async throws {
        let provider = MockLLMProvider(scenes: [.text("ok"), .text("ok2")])
        let messages: [Message] = [.user("ping")]
        let tools = [
            ToolDefinition(name: "x", description: "", inputSchema: .object(properties: [:]))
        ]
        let options = GenerationOptions(temperature: 0.7)

        _ = try await self.collect(provider.stream(messages: messages, tools: tools, options: options))
        _ = try await self.collect(provider.stream(messages: messages, tools: [], options: .init()))

        XCTAssertEqual(provider.invocations.count, 2)
        XCTAssertEqual(provider.invocations[0].messages, messages)
        XCTAssertEqual(provider.invocations[0].tools.count, 1)
        XCTAssertEqual(provider.invocations[0].options.temperature, 0.7)
        XCTAssertTrue(provider.invocations[1].tools.isEmpty)
    }

    func testEnqueueAppendsScenes() async throws {
        let provider = MockLLMProvider(scenes: [.text("first")])
        provider.enqueue(.text("second"))

        let firstEvents = try await collect(provider.stream(messages: [], tools: [], options: .init()))
        let secondEvents = try await collect(provider.stream(messages: [], tools: [], options: .init()))

        XCTAssertTrue(firstEvents.contains(.textDelta("first")))
        XCTAssertTrue(secondEvents.contains(.textDelta("second")))
    }

    func testToolCallSceneEmitsExpectedEvents() async throws {
        let provider = MockLLMProvider(scenes: [
            .toolCall(
                id: "call-1",
                name: "lookup",
                arguments: .object(["q": .string("aria")])
            )
        ])

        let events = try await collect(provider.stream(messages: [], tools: [], options: .init()))

        let hasToolCallStart = events.contains { event in
            if case let .toolCallStart(call) = event {
                call.id == "call-1" && call.name == "lookup"
            } else {
                false
            }
        }
        XCTAssertTrue(hasToolCallStart)
        XCTAssertTrue(events.contains(.toolCallEnd(id: "call-1")))
        XCTAssertTrue(events.contains(.messageStop(.toolUse)))
    }

    // MARK: Private

    // MARK: - Helpers

    private func collect(
        _ stream: AsyncThrowingStream<ProviderEvent, any Error>
    ) async throws -> [ProviderEvent] {
        var result: [ProviderEvent] = []
        for try await event in stream {
            result.append(event)
        }
        return result
    }
}
