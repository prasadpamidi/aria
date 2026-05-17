import Foundation
import XCTest
@testable import Aria

/// Tests-first spec for `FactExtractionMiddleware`.
///
/// Runs in `afterStep` (after the assistant has replied) and scans the
/// just-finished user turn for durable facts the model didn't explicitly
/// call `remember_user_fact` on. Writes extracted facts to a
/// `MemoryStore` so they survive across threads. Background, fail-open.
final class FactExtractionMiddlewareTests: XCTestCase {
    // MARK: Internal

    // MARK: - Trigger gating

    func testExtractsFromLatestUserTurnAfterStep() async throws {
        let extractor = RecordingExtractor(facts: ["user is vegetarian"])
        let memory = RecordingMemory()
        let middleware = self.makeMiddleware(extractor: extractor, memory: memory)
        let state = AgentState(threadId: "t", messages: [
            .user("hi"),
            .assistant("hey"),
            .user("by the way, I'm vegetarian")
        ])
        _ = try await middleware.afterStep(state)
        let calls = await extractor.invocations
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].textContent, "by the way, I'm vegetarian")
        let stored = await memory.remembered
        XCTAssertEqual(stored.map(\.content), ["user is vegetarian"])
    }

    func testNoOpWhenLatestMessageIsNotUser() async throws {
        // Only user turns carry user-asserted facts. After-step often
        // fires with the assistant's reply as the latest message —
        // skip those.
        let extractor = RecordingExtractor(facts: ["nope"])
        let memory = RecordingMemory()
        let middleware = self.makeMiddleware(extractor: extractor, memory: memory)
        let state = AgentState(threadId: "t", messages: [
            .user("hi"),
            .assistant("I should not have facts extracted from me")
        ])
        _ = try await middleware.afterStep(state)
        let calls = await extractor.invocations.count
        XCTAssertEqual(calls, 0)
        let stored = await memory.remembered.count
        XCTAssertEqual(stored, 0)
    }

    func testNoOpWhenStateIsEmpty() async throws {
        let extractor = RecordingExtractor(facts: ["nothing"])
        let memory = RecordingMemory()
        let middleware = self.makeMiddleware(extractor: extractor, memory: memory)
        let state = AgentState(threadId: "t", messages: [])
        _ = try await middleware.afterStep(state)
        let calls = await extractor.invocations.count
        XCTAssertEqual(calls, 0)
    }

    // MARK: - Multiple facts

    func testWritesEachExtractedFactAsSeparateMemoryItem() async throws {
        let extractor = RecordingExtractor(facts: [
            "user is vegetarian",
            "user lifts 4x per week",
            "user has a knee injury"
        ])
        let memory = RecordingMemory()
        let middleware = self.makeMiddleware(extractor: extractor, memory: memory)
        let state = AgentState(threadId: "t", messages: [
            .user("I'm vegetarian, lift 4x/week, and have a bad knee")
        ])
        _ = try await middleware.afterStep(state)
        let stored = await memory.remembered.map(\.content)
        XCTAssertEqual(Set(stored), [
            "user is vegetarian",
            "user lifts 4x per week",
            "user has a knee injury"
        ])
    }

    func testWritesNothingWhenExtractorReturnsEmpty() async throws {
        let extractor = RecordingExtractor(facts: [])
        let memory = RecordingMemory()
        let middleware = self.makeMiddleware(extractor: extractor, memory: memory)
        let state = AgentState(threadId: "t", messages: [
            .user("just a question, no durable facts here")
        ])
        _ = try await middleware.afterStep(state)
        let calls = await extractor.invocations.count
        XCTAssertEqual(calls, 1)
        let stored = await memory.remembered.count
        XCTAssertEqual(stored, 0)
    }

    // MARK: - Graceful degradation

    func testGracefulFallthroughWhenExtractorThrows() async throws {
        // A failing extractor (rate limit, network down) must not
        // break the turn — the agent has already completed when
        // afterStep fires; an extractor failure should leave state
        // alone and write nothing.
        let extractor = RecordingExtractor(shouldThrow: true)
        let memory = RecordingMemory()
        let middleware = self.makeMiddleware(extractor: extractor, memory: memory)
        let state = AgentState(threadId: "t", messages: [
            .user("anything goes")
        ])
        let out = try await middleware.afterStep(state)
        XCTAssertEqual(out.messages.count, 1)
        let stored = await memory.remembered.count
        XCTAssertEqual(stored, 0)
    }

    // MARK: - Metadata

    func testExtractedFactsAreTaggedWithThreadIdAndSource() async throws {
        // Useful for later auditability — a user reviewing what Niora
        // remembers should be able to trace back to which thread the
        // fact came from. The `source = "auto_extracted"` tag also
        // distinguishes these from facts the model explicitly called
        // `remember_user_fact` on, in case we want different retention
        // or display rules.
        let extractor = RecordingExtractor(facts: ["fact-1"])
        let memory = RecordingMemory()
        let middleware = self.makeMiddleware(extractor: extractor, memory: memory)
        let state = AgentState(threadId: "specific-thread", messages: [
            .user("source me")
        ])
        _ = try await middleware.afterStep(state)
        let stored = await memory.remembered
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored[0].metadata["source"], .string("auto_extracted"))
        XCTAssertEqual(stored[0].metadata["thread_id"], .string("specific-thread"))
    }

    // MARK: - State preservation

    func testReturnsStateUnchangedWhenExtractionSucceeds() async throws {
        let extractor = RecordingExtractor(facts: ["one"])
        let memory = RecordingMemory()
        let middleware = self.makeMiddleware(extractor: extractor, memory: memory)
        let original = AgentState(threadId: "t", messages: [
            .user("hi"),
            .assistant("yo"),
            .user("save this fact")
        ])
        let out = try await middleware.afterStep(original)
        // afterStep can't mutate the persisted message stream — fact
        // extraction is observational only.
        XCTAssertEqual(out.messages.count, 3)
        XCTAssertEqual(out.threadId, "t")
    }

    // MARK: Private

    // MARK: - Test helpers

    /// Captures every call to the extractor and returns canned facts.
    private actor RecordingExtractor {
        // MARK: Lifecycle

        init(facts: [String] = [], shouldThrow: Bool = false) {
            self.facts = facts
            self.shouldThrow = shouldThrow
        }

        // MARK: Internal

        private(set) var invocations: [Message] = []

        func extract(from message: Message) async throws -> [String] {
            self.invocations.append(message)
            if self.shouldThrow {
                throw NSError(domain: "test.extractor", code: 1)
            }
            return self.facts
        }

        // MARK: Private

        private let facts: [String]
        private let shouldThrow: Bool
    }

    /// Captures every memory write so tests can verify what got stored.
    private actor RecordingMemory: MemoryStore {
        private(set) var remembered: [MemoryItem] = []

        func remember(_ item: MemoryItem, namespace: [String]) async throws -> MemoryRef {
            self.remembered.append(item)
            return MemoryRef(id: item.id, namespace: namespace)
        }

        func recall(
            query _: String,
            namespace _: [String],
            topK _: Int,
            filter _: VectorFilter?
        ) async throws -> [MemoryMatch] {
            []
        }

        func forget(id _: String, namespace _: [String]) async throws { }

        func list(namespace _: [String], limit _: Int) async throws -> [MemoryItem] {
            self.remembered
        }
    }

    private func makeMiddleware(
        extractor: RecordingExtractor,
        memory: RecordingMemory,
        namespace: [String] = ["user"]
    ) -> FactExtractionMiddleware {
        FactExtractionMiddleware(
            memory: memory,
            namespace: namespace,
            extractor: { message in
                try await extractor.extract(from: message)
            }
        )
    }
}
