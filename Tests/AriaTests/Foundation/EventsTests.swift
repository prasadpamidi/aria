import Foundation
import XCTest
@testable import Aria

final class EventsTests: XCTestCase {
    func testProviderEventEquatable() {
        let event1: ProviderEvent = .textDelta("hello")
        let event2: ProviderEvent = .textDelta("hello")
        let event3: ProviderEvent = .textDelta("world")

        XCTAssertEqual(event1, event2)
        XCTAssertNotEqual(event1, event3)
    }

    func testFinishReasonCodableRoundTrip() throws {
        let reasons: [FinishReason] = [
            .endTurn,
            .maxTokens,
            .toolUse,
            .stopSequence,
            .refusal,
            .error,
            .maxStepsReached,
            .cancelled
        ]
        let data = try JSONEncoder().encode(reasons)
        let decoded = try JSONDecoder().decode([FinishReason].self, from: data)
        XCTAssertEqual(decoded, reasons)
    }

    func testTokenUsageCodableRoundTrip() throws {
        let usage = TokenUsage(
            inputTokens: 100,
            outputTokens: 200,
            cacheReadTokens: 50,
            cacheCreationTokens: nil
        )
        let data = try JSONEncoder().encode(usage)
        let decoded = try JSONDecoder().decode(TokenUsage.self, from: data)
        XCTAssertEqual(decoded, usage)
    }

    func testToolExecutionResultEquality() {
        let r1 = ToolExecutionResult(
            output: .object(["status": .string("ok")]),
            isError: false,
            duration: .milliseconds(120)
        )
        let r2 = ToolExecutionResult(
            output: .object(["status": .string("ok")]),
            isError: false,
            duration: .milliseconds(120)
        )
        XCTAssertEqual(r1, r2)
    }

    func testAgentErrorPatternMatching() {
        let err = AgentError.maxStepsReached(10)
        if case let .maxStepsReached(steps) = err {
            XCTAssertEqual(steps, 10)
        } else {
            XCTFail("Expected maxStepsReached")
        }
    }
}
