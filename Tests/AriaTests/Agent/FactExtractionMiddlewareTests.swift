import Foundation
import XCTest
@testable import Aria

/// Tests-first spec for `FactExtractionMiddleware`.
///
/// Runs in `afterStep` (after the assistant has replied) and scans
/// the just-finished user turn for durable facts, proposing each
/// one to a `MemoryGate`. The gate owns validation + dedup + the
/// write — these tests cover the middleware's responsibilities:
/// gating on user turn, multi-fact decomposition, fail-open on
/// extractor errors, metadata pass-through, and state preservation.
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
        // Source ("auto_extracted") is stamped by the gate; thread_id
        // is forwarded by the middleware via its extraMetadata
        // closure. Verifies both ends of the contract land on the
        // same MemoryItem.
        let extractor = RecordingExtractor(facts: ["user lives in Berlin"])
        let memory = RecordingMemory()
        let middleware = FactExtractionMiddleware(
            gate: self.makePassthroughGate(memory: memory),
            extractor: { _ in ["user lives in Berlin"] },
            extraMetadata: { state in ["thread_id": .string(state.threadId)] }
        )
        let state = AgentState(threadId: "specific-thread", messages: [
            .user("source me")
        ])
        _ = try await middleware.afterStep(state)
        let stored = await memory.remembered
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored[0].metadata["source"], .string("auto_extracted"))
        XCTAssertEqual(stored[0].metadata["thread_id"], .string("specific-thread"))
    }

    func testSkipsFactsAlreadyPresentAboveSimilarityThreshold() async throws {
        // Dedup lives in the gate now. The middleware just proposes;
        // the gate's threshold decides. Above-threshold matches must
        // not result in a write.
        let memory = RecordingMemoryWithRecall(recallScore: 0.95)
        let middleware = FactExtractionMiddleware(
            gate: ValidatingMemoryGate(
                store: memory,
                namespace: ["user"],
                dedupThreshold: 0.9,
                normalize: { fact, _ in fact }
            ),
            extractor: { _ in ["user is vegetarian"] }
        )
        let state = AgentState(threadId: "t", messages: [.user("anything")])
        _ = try await middleware.afterStep(state)
        let stored = await memory.remembered.count
        XCTAssertEqual(stored, 0)
    }

    func testWritesFactsBelowSimilarityThreshold() async throws {
        // A fact only weakly similar (0.5) to anything in memory is
        // genuinely new — write it.
        let memory = RecordingMemoryWithRecall(recallScore: 0.5)
        let middleware = FactExtractionMiddleware(
            gate: ValidatingMemoryGate(
                store: memory,
                namespace: ["user"],
                dedupThreshold: 0.9,
                normalize: { fact, _ in fact }
            ),
            extractor: { _ in ["user is vegetarian"] }
        )
        let state = AgentState(threadId: "t", messages: [.user("anything")])
        _ = try await middleware.afterStep(state)
        let stored = await memory.remembered.map(\.content)
        XCTAssertEqual(stored, ["user is vegetarian"])
    }

    func testDedupDisabledWhenThresholdIsNil() async throws {
        // Nil threshold on the gate = no dedup pass — write
        // everything the extractor returns. Matches pre-dedup
        // behavior.
        let memory = RecordingMemoryWithRecall(recallScore: 0.99)
        let middleware = FactExtractionMiddleware(
            gate: ValidatingMemoryGate(
                store: memory,
                namespace: ["user"],
                dedupThreshold: nil,
                normalize: { fact, _ in fact }
            ),
            extractor: { _ in ["near dup fact"] }
        )
        let state = AgentState(threadId: "t", messages: [.user("anything")])
        _ = try await middleware.afterStep(state)
        let stored = await memory.remembered.count
        XCTAssertEqual(stored, 1)
    }

    // MARK: - Gate validator gating

    func testValidatorRejectionStopsWriteEvenWhenExtractorReturnedFact() async throws {
        // The gate's validator is the load-bearing safeguard against
        // weak chat models proposing world knowledge. A normalize
        // closure that returns nil = "not a durable user fact" must
        // result in no write, even when the extractor is happy.
        let memory = RecordingMemory()
        let middleware = FactExtractionMiddleware(
            gate: ValidatingMemoryGate(
                store: memory,
                namespace: ["user"],
                normalize: { _, _ in nil }
            ),
            extractor: { _ in ["India is in South Asia"] }
        )
        let state = AgentState(threadId: "t", messages: [.user("tell me about India")])
        _ = try await middleware.afterStep(state)
        let stored = await memory.remembered.count
        XCTAssertEqual(stored, 0)
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

    // MARK: - Dedup against existing memories

    /// Mock memory store with controllable recall scores — lets us
    /// drive the dedup branch deterministically.
    private actor RecordingMemoryWithRecall: MemoryStore {
        // MARK: Lifecycle

        init(recallScore: Float, recallContent: String = "existing similar fact") {
            self.recallScore = recallScore
            self.recallContent = recallContent
        }

        // MARK: Internal

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
            [MemoryMatch(item: MemoryItem(content: self.recallContent), score: self.recallScore)]
        }

        func forget(id _: String, namespace _: [String]) async throws { }
        func list(namespace _: [String], limit _: Int) async throws -> [MemoryItem] {
            self.remembered
        }

        // MARK: Private

        private let recallScore: Float
        private let recallContent: String
    }

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

    /// Gate that accepts every proposal verbatim and skips dedup.
    /// The "passthrough" baseline for tests that aren't asserting
    /// validator or dedup behavior.
    private func makePassthroughGate(memory: any MemoryStore) -> ValidatingMemoryGate {
        ValidatingMemoryGate(
            store: memory,
            namespace: ["user"],
            dedupThreshold: nil,
            normalize: { fact, _ in fact }
        )
    }

    private func makeMiddleware(
        extractor: RecordingExtractor,
        memory: any MemoryStore,
        namespace _: [String] = ["user"]
    ) -> FactExtractionMiddleware {
        FactExtractionMiddleware(
            gate: self.makePassthroughGate(memory: memory),
            extractor: { message in
                try await extractor.extract(from: message)
            }
        )
    }
}
